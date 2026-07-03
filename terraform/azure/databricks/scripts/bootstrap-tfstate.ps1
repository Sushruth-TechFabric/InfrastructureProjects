<#
.SYNOPSIS
    Bootstraps the Terraform remote-state backend (resource group + storage
    account + container) for one environment. This solves the "chicken-and-egg"
    problem: Terraform needs a backend to store state, but the backend itself
    cannot be created by Terraform without already having one.

    Run this ONCE per deployment boundary (dev / qa / prod / shared-services)
    BEFORE the first `terraform init` for that boundary.

.DESCRIPTION
    Creates, per the platform naming convention {type}-{workload}-{env}-{region}-{instance}:
      - rg-tfstate-<env>-<regionAbbrev>-<instance>
      - st tfstate <env> <regionAbbrev> <instance>   (<=24 chars, lowercase+digits)
      - a blob container (default: tfstate)

    Security posture applied here:
      - TLS 1.2 minimum, anonymous blob access off.
      - public-network-access ENABLED but default-action DENY, locked to an IP
        allowlist (your current public IP by default, plus any -AllowedIpAddress).
      - blob versioning + 30-day soft delete (state recovery).
      - CanNotDelete lock on the resource group.
      - the running principal is granted "Storage Blob Data Contributor" so that
        container creation via --auth-mode login (and later Terraform) works.

    NOT applied here (deferred state-backend hardening — see
    docs/architecture and the deferred-for-client note):
      - private endpoint + private DNS zone (would replace the IP allowlist).
      - public-network-access Disabled (only safe once the PE exists; otherwise
        nothing — not your CLI, not CI — can reach the backend).

.PARAMETER Environment
    dev | qa | prod | shared | dev-lab. Drives the resource names.
    dev-lab is the per-person cost-optimized lab (ADR-0006) — each teammate
    runs this against their OWN subscription.

.PARAMETER Location
    Azure region long name, e.g. eastus2.

.PARAMETER RegionAbbrev
    Short region token used in names (e.g. eus2). Defaults from a small map for
    common regions; pass explicitly for anything not in the map.

.PARAMETER Instance
    Zero-padded instance number. Default "001".

.PARAMETER StorageAccountName
    Override the derived storage account name. Storage account names must be
    globally unique, 3-24 chars, lowercase letters + digits only. Use this if the
    derived name collides with an existing global name.

.PARAMETER ContainerName
    Blob container for state. Default "tfstate".

.PARAMETER SubscriptionId
    Optional. Target subscription; if omitted the current `az account` context is used.

.PARAMETER AllowedIpAddress
    Extra public IP(s)/CIDR(s) to allow through the storage firewall (e.g. CI
    egress ranges). Your current public IP is always added automatically.

.PARAMETER SkipLock
    Skip creating the CanNotDelete lock (useful in throwaway dev sandboxes).

.PARAMETER Recreate
    DESTRUCTIVE. Tear the backend down before recreating it: remove the
    CanNotDelete lock and delete the entire resource group (and ANY Terraform
    state stored in it), then proceed with a fresh create. Requires typing the
    resource group name to confirm. Sandbox use only — never against a backend
    holding state you care about. Without this switch the script only ever
    creates/updates (converges); it never deletes.

.EXAMPLE
    ./scripts/bootstrap-tfstate.ps1 -Environment dev -Location eastus2

.EXAMPLE
    ./scripts/bootstrap-tfstate.ps1 -Environment prod -Location eastus2 `
        -AllowedIpAddress '203.0.113.10','198.51.100.0/24'

.EXAMPLE
    # Wipe and rebuild a dev sandbox backend from scratch:
    ./scripts/bootstrap-tfstate.ps1 -Environment dev -Location eastus2 -Recreate
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'qa', 'prod', 'shared', 'dev-lab')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$Location,

    [string]$RegionAbbrev,

    [ValidatePattern('^\d{3}$')]
    [string]$Instance = '001',

    [string]$StorageAccountName,

    [string]$ContainerName = 'tfstate',

    [string]$SubscriptionId,

    [string[]]$AllowedIpAddress = @(),

    [switch]$SkipLock,

    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail($msg) { Write-Error $msg; exit 1 }

# --- preflight -------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail 'Azure CLI (az) not found on PATH. Install it and run `az login` first.'
}

# Common region long-name -> abbreviation map. Extend as needed, or pass -RegionAbbrev.
$regionMap = @{
    'eastus'        = 'eus'
    'eastus2'       = 'eus2'
    'centralus'     = 'cus'
    'westus2'       = 'wus2'
    'westus3'       = 'wus3'
    'westeurope'    = 'weu'
    'northeurope'   = 'neu'
    'uksouth'       = 'uks'
    'southeastasia' = 'sea'
}
if (-not $RegionAbbrev) {
    $key = $Location.ToLower()
    if (-not $regionMap.ContainsKey($key)) {
        Fail "No region abbreviation known for '$Location'. Pass -RegionAbbrev explicitly (e.g. -RegionAbbrev eus2)."
    }
    $RegionAbbrev = $regionMap[$key]
}

# --- subscription context (resolved first: needed for the unique suffix) ----
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}
$ctx = az account show -o json 2>$null | ConvertFrom-Json
if (-not $ctx) { Fail 'Not logged in. Run `az login` (and `az account set --subscription <id>`).' }

# --- derive names (platform naming convention) -----------------------------
$rg = "rg-tfstate-$Environment-$RegionAbbrev-$Instance"

if (-not $StorageAccountName) {
    # Storage account names are GLOBALLY unique across all of Azure, so the
    # instance number alone can collide with an account in another subscription
    # or tenant. Append a short suffix derived deterministically from the
    # subscription id: the same subscription always yields the same name, so the
    # script stays idempotent (re-running does not spawn a second account).
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($ctx.id))
    $suffix = (-join ($hash[0..1] | ForEach-Object { $_.ToString('x2') }))  # 4 hex chars
    $base = ("sttfstate$Environment$RegionAbbrev$Instance").ToLower() -replace '[^a-z0-9]', ''
    # Keep the whole name <=24 chars; trim the base (not the suffix) if needed.
    $maxBase = 24 - $suffix.Length
    if ($base.Length -gt $maxBase) { $base = $base.Substring(0, $maxBase) }
    $StorageAccountName = "$base$suffix"
}
if ($StorageAccountName.Length -gt 24 -or $StorageAccountName.Length -lt 3) {
    Fail "Storage account name '$StorageAccountName' is $($StorageAccountName.Length) chars; must be 3-24. Pass -StorageAccountName to override."
}
if ($StorageAccountName -cnotmatch '^[a-z0-9]+$') {
    Fail "Storage account name '$StorageAccountName' must be lowercase letters and digits only."
}

Write-Host "Resource group : $rg"           -ForegroundColor Cyan
Write-Host "Storage account: $StorageAccountName" -ForegroundColor Cyan
Write-Host "Container       : $ContainerName"  -ForegroundColor Cyan
Write-Host "Location        : $Location ($RegionAbbrev)" -ForegroundColor Cyan
Write-Host "Subscription    : $($ctx.name) ($($ctx.id))" -ForegroundColor Cyan

# --- optional teardown (-Recreate) -----------------------------------------
# DESTRUCTIVE: removes the lock + deletes the whole RG (and any state) so the
# steps below rebuild from scratch. Guarded by a typed confirmation.
if ($Recreate) {
    if ((az group exists --name $rg) -eq 'true') {
        Write-Host "`n[!] -Recreate requested. This will PERMANENTLY DELETE:" -ForegroundColor Red
        Write-Host "      - resource group : $rg" -ForegroundColor Red
        Write-Host "      - storage account: $StorageAccountName" -ForegroundColor Red
        Write-Host "      - container       : $ContainerName (and ANY Terraform state in it)" -ForegroundColor Red
        Write-Host "    This cannot be undone." -ForegroundColor Red
        $answer = Read-Host "    Proceed? Type 'yes' to continue, anything else to abort"
        if ($answer -notin @('y', 'yes')) { Fail 'Aborted by user; nothing was deleted.' }

        # The CanNotDelete lock must go first, or the RG delete is blocked.
        $lockId = az lock show --name 'cannotdelete-tfstate' --resource-group $rg --query id -o tsv 2>$null
        if ($lockId) {
            Write-Host "    Removing CanNotDelete lock..." -ForegroundColor Yellow
            az lock delete --ids $lockId --only-show-errors | Out-Null
        }
        Write-Host "    Deleting resource group (waiting for completion)..." -ForegroundColor Yellow
        az group delete --name $rg --yes --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Resource group '$rg' could not be deleted." }
        Write-Host "    Teardown complete." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n[!] -Recreate: resource group '$rg' does not exist; nothing to tear down." -ForegroundColor Yellow
    }
}

# --- 1. resource group -----------------------------------------------------
Write-Host "`n[1/6] Creating resource group..." -ForegroundColor Green
az group create --name $rg --location $Location --only-show-errors | Out-Null

# --- 2. storage account ----------------------------------------------------
# default-action Deny + public access ENABLED so an IP allowlist still applies.
# (With public-network-access Disabled, firewall rules are ignored and nothing
#  could reach the backend without a private endpoint.)
Write-Host "[2/6] Creating storage account (TLS1.2, no anon, default-deny)..." -ForegroundColor Green
az storage account create `
    --name $StorageAccountName --resource-group $rg --location $Location `
    --sku Standard_LRS --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false `
    --public-network-access Enabled `
    --default-action Deny `
    --only-show-errors | Out-Null
# az is a native exe: a non-zero exit does NOT trip $ErrorActionPreference, so
# check it explicitly. Otherwise a failed create cascades into a confusing
# "ResourceNotFound" / "--scope: expected one argument" further down.
if ($LASTEXITCODE -ne 0) {
    Fail "Storage account '$StorageAccountName' could not be created. The name may already be taken globally (it must be unique across all of Azure). Re-run with -StorageAccountName <name> to override, or change -Instance."
}

# --- 3. firewall allowlist (current IP + any extras) -----------------------
Write-Host "[3/6] Allowlisting IPs through the storage firewall..." -ForegroundColor Green
$myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
$ipList = @($myIp) + $AllowedIpAddress | Where-Object { $_ } | Select-Object -Unique
foreach ($ip in $ipList) {
    Write-Host "       allow $ip"
    az storage account network-rule add `
        --account-name $StorageAccountName --resource-group $rg `
        --ip-address $ip --only-show-errors | Out-Null
}

# --- 4. data-plane RBAC for the running principal --------------------------
# `--auth-mode login` and Terraform's azurerm backend (use_azuread_auth) need a
# DATA-plane role; control-plane Owner/Contributor is NOT enough.
Write-Host "[4/6] Granting 'Storage Blob Data Contributor' to current principal..." -ForegroundColor Green
$signedInId = az ad signed-in-user show --query id -o tsv 2>$null
$saId = az storage account show --name $StorageAccountName --resource-group $rg --query id -o tsv
if ($signedInId) {
    az role assignment create `
        --assignee $signedInId `
        --role 'Storage Blob Data Contributor' `
        --scope $saId --only-show-errors | Out-Null
    Write-Host "       waiting ~30s for RBAC + firewall propagation..."
    Start-Sleep -Seconds 30
}
else {
    Write-Warning 'Could not resolve signed-in user (service principal context?). Ensure the running principal has "Storage Blob Data Contributor" on the account, then re-run.'
}

# --- 5. blob versioning + soft delete, then container ----------------------
Write-Host "[5/6] Enabling versioning + soft delete, creating container..." -ForegroundColor Green
az storage account blob-service-properties update `
    --account-name $StorageAccountName --resource-group $rg `
    --enable-versioning true `
    --enable-delete-retention true --delete-retention-days 30 `
    --only-show-errors | Out-Null

# Retry container creation: RBAC/firewall propagation can lag the sleep above.
$created = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        az storage container create `
            --name $ContainerName --account-name $StorageAccountName `
            --auth-mode login --only-show-errors | Out-Null
        $created = $true; break
    }
    catch {
        Write-Host "       container create attempt $i failed; retrying in 15s..."
        Start-Sleep -Seconds 15
    }
}
if (-not $created) {
    Fail "Container creation failed. Likely RBAC/firewall not yet propagated, or your IP ($myIp) is not allowed. Re-run the script (it is idempotent)."
}

# --- 6. resource-group lock ------------------------------------------------
if (-not $SkipLock) {
    Write-Host "[6/6] Applying CanNotDelete lock on the resource group..." -ForegroundColor Green
    az lock create `
        --name 'cannotdelete-tfstate' `
        --lock-type CanNotDelete `
        --resource-group $rg --only-show-errors | Out-Null
}
else {
    Write-Host "[6/6] Skipping resource-group lock (-SkipLock)." -ForegroundColor Yellow
}

# --- done: emit backend config --------------------------------------------
$stateKey = if ($Environment -eq 'shared') { 'shared-services/terraform.tfstate' } else { "environments/$Environment/terraform.tfstate" }

Write-Host "`nBackend bootstrap complete. Add this to the matching root config:" -ForegroundColor Green
Write-Host @"

terraform {
  backend "azurerm" {
    resource_group_name  = "$rg"
    storage_account_name = "$StorageAccountName"
    container_name       = "$ContainerName"
    key                  = "$stateKey"
    use_azuread_auth     = true   # data-plane auth via your Entra identity / CI OIDC; no account key
  }
}
"@ -ForegroundColor Gray

Write-Host "NOTE: 'az login' identities and CI OIDC principals must (a) be allowlisted IPs and" -ForegroundColor Yellow
Write-Host "      (b) hold 'Storage Blob Data Contributor' on the account to use this backend." -ForegroundColor Yellow
Write-Host "TODO (deferred hardening): add a private endpoint + private DNS zone, then flip" -ForegroundColor Yellow
Write-Host "      public-network-access to Disabled and drop the IP allowlist." -ForegroundColor Yellow
