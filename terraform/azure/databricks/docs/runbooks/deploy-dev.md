# Runbook — Deploy the `dev` environment

Step-by-step guide to stand up (and tear down) the secure Databricks dev
environment. Explains what each step does, what each command does, and what to
look for when reviewing the plans. Architecture rationale lives in
[`docs/architecture/azure-platform-architecture.md`](../architecture/azure-platform-architecture.md);
this document is purely operational.

> **Lab context:** this platform runs in ephemeral deploy/destroy sessions under
> a monthly cost ceiling. The Azure Firewall meter (~$1.25/hr Standard tier,
> ~$30/day with NAT + IPs) starts at shared-services apply — always destroy at
> the end of a session (Step 6).

---

## The files, and what each one does

Every deployment boundary (`shared-services`, `environments/{dev,qa,prod}`) is a
self-contained Terraform root with **its own state file**. Within each root:

| File | Role |
|---|---|
| `backend.tf` | Where state lives — an Azure Storage blob, authenticated via your Entra identity (`use_azuread_auth = true`), no storage keys. |
| `providers.tf` | Pins Terraform + provider versions; configures `azurerm` (Azure resources) and, in dev, `databricks` (workspace-level settings). |
| `variables.tf` | Declares inputs (types, descriptions) — no values. |
| `terraform.tfvars` | The **only place the environment's concrete values live**: subscription id, CIDRs, names, allowed IPs, tags. Non-secret by design. |
| `main.tf` | Instantiates the reusable modules and does cross-boundary glue: hub lookups, VNet peering, DNS zone links, private endpoints, RBAC. |
| `workspace-config.tf` (dev) | "Pass 2" — controls *inside* the workspace: IP access list, cluster policies, Key Vault-backed secret scope. |
| `outputs.tf` | Values printed after apply (names, IPs, workspace URL). |

`modules/` (networking, storage, key-vault, identity, databricks-workspace) are
environment-agnostic blueprints — every environment calls the same module code
with different tfvars. `scripts/bootstrap-tfstate.ps1` solves the chicken-and-egg
problem: Terraform needs somewhere to store state before Terraform can run, so
the state storage account is created once with the Azure CLI.

**Deploy order is not optional.** Dev resolves the hub firewall, hub VNet, and
the four Private DNS zones **by name via data sources at plan time**
(the cross-state contract — no `terraform_remote_state`, no hardcoded IDs).
Until shared-services is applied, `terraform plan` in dev fails with six
"not found" errors. That is the contract working as designed.

---

## Step 0 — Prerequisites

```powershell
az login
az account set --subscription <dev-subscription-guid>   # must match terraform.tfvars
terraform version    # >= 1.9 required (pinned in providers.tf)
curl ifconfig.me     # your current public egress IP
```

Your egress IP must appear in **two** places, or you lock yourself out:

1. The state storage accounts' firewall allowlists (set at bootstrap; add with
   `az storage account network-rule add` if your IP changed) — otherwise
   `terraform init` cannot reach state.
2. `allowed_ip_addresses` in `environments/dev/terraform.tfvars` — otherwise the
   workspace IP access list applied in pass 2 blocks you (and Terraform) from
   the workspace front-end.

## Step 1 — Bootstrap the state backends (once per boundary, likely already done)

```powershell
./scripts/bootstrap-tfstate.ps1 -Environment shared -Location westus3
./scripts/bootstrap-tfstate.ps1 -Environment dev    -Location westus3
```

Creates `rg-tfstate-<env>-wus3-001` with a hardened storage account: TLS 1.2
minimum, default-deny firewall allowlisting your IP, blob versioning + 30-day
soft delete (state recovery), a `CanNotDelete` lock, and a
`Storage Blob Data Contributor` grant to you (the backend uses data-plane Entra
auth, so control-plane Owner is not enough). The account name embeds a
subscription-derived hash — paste the script's output into the matching
`backend.tf`. Idempotent; re-running converges and never deletes.

Skip if `az group exists --name rg-tfstate-dev-wus3-001` returns `true`.

## Step 2 — Deploy shared-services (the hub)

```powershell
cd shared-services
terraform init
terraform plan -out=tfplan-shared
# review the diff (see "Reviewing the plans" below)
terraform apply tfplan-shared
```

- `init` — wires the directory to its remote state blob and installs the exact
  provider versions recorded in `.terraform.lock.hcl`.
- `plan -out=` — computes the diff between config, state, and real Azure, and
  saves it so `apply` executes **exactly** what was reviewed, nothing recomputed.
  A saved plan goes stale if reality changes — re-plan rather than applying an
  old file.
- `apply <planfile>` — executes the reviewed plan. The Azure Firewall alone
  takes **10–15 minutes**.

Expected on a fresh subscription: **15 to add, 0 to change, 0 to destroy** —
hub RG, hub VNet (10.0.0.0/24) with `AzureFirewallSubnet` (the name is an Azure
requirement), Azure Firewall + policy + egress rule collection, NAT gateway +
2 public IPs + 2 associations (the stable-egress pattern, ADR-0004 — this is why
the firewall is non-zonal), and the four Private DNS zones (blob, dfs,
vaultcore, azuredatabricks).

## Step 3 — Deploy dev, pass 1 (Azure infra layer)

```powershell
cd ../environments/dev
terraform init
terraform plan -target=module.databricks_workspace -out=tfplan-dev-p1
# review, then:
terraform apply tfplan-dev-p1
```

**Why `-target`:** `providers.tf` points the `databricks` provider at the
workspace this same config creates (`azure_workspace_resource_id`). On a fresh
deploy the workspace does not exist, so the provider cannot authenticate and a
full plan fails on every `databricks_*` resource with
`failed to validate workspace_id`. Targeting the workspace module first builds
just its dependency chain: resource groups → spoke VNet, delegated host +
container subnets, NSGs, forced-tunnel route (0.0.0.0/0 → hub firewall) → the
SCC / VNet-injected workspace. This two-phase ordering is documented in
`providers.tf` and ADR-0002.

## Step 4 — Deploy dev, pass 2 (everything else)

```powershell
terraform plan -out=tfplan-dev-p2
# review, then:
terraform apply tfplan-dev-p2
```

Creates the remaining Azure resources — ADLS Gen2 (bronze/silver/gold), Key
Vault, Access Connector + user-assigned identity, VNet peering (both halves,
created from the spoke), the four Private DNS zone **links** (forgetting these
is the classic silent failure: the PE exists but names still resolve to public
IPs), four private endpoints (blob, dfs, vault, databricks back-end), and the
`Storage Blob Data Contributor` grant to the connector identity (secretless
data access) — plus the in-workspace controls from `workspace-config.tf`:
IP access list, three cluster policies (personal / jobs / shared), and the
Key Vault-backed secret scope.

## Step 5 — Verify

```powershell
terraform output          # workspace URL, resource names
```

Open the workspace URL from an allowed IP; log in with Entra ID. Launch a
policy-governed cluster — if it hangs at startup, the first suspect is the
firewall egress allowlist (`TODO(region-endpoints)` in
`shared-services/main.tf`): reconcile it against the current region-specific
Databricks endpoint list on Microsoft Learn.

## Step 6 — Tear down (end of session)

```powershell
cd environments/dev && terraform destroy        # spoke first
cd ../../shared-services && terraform destroy   # hub second
```

Reverse order: the hub cannot cleanly delete while spoke peerings / DNS links
still reference it. The state backends stay (they cost pennies) so the next
session starts at Step 2.

---

## Reviewing the plans — what to actually check

The plan diff is the review artifact; the version number is not. Line-by-line
checklist for the dev plans:

- **Sealed data plane:** `public_network_access_enabled = false` on the storage
  account and Key Vault; `no_public_ip = true` (SCC) on the workspace.
- **DNS:** every `azurerm_private_endpoint` has a `private_dns_zone_group`
  block, and every zone used has a matching
  `azurerm_private_dns_zone_virtual_network_link` to the spoke VNet.
- **RBAC:** exactly `Storage Blob Data Contributor`, scoped to the single
  storage account, principal = the Access Connector's user-assigned identity.
  No `Contributor`/`Owner` anywhere.
- **Routing:** the route table sends `0.0.0.0/0` to the hub firewall's private
  IP and is associated to both Databricks subnets.
- **Tags:** `Environment`, `Owner`, `CostCenter`, `ManagedBy=terraform`,
  `Project` on every resource.
- **On re-runs:** anything under `to change` or `to destroy` needs an
  explanation before apply — a create-only plan is the safe baseline.

## Failure modes seen in practice

| Symptom | Cause |
|---|---|
| `terraform init` → 403 on the backend | Your egress IP is not on the state storage firewall, or you lack `Storage Blob Data Contributor` (data-plane) on the account. |
| Dev plan: 6 × "not found" (firewall, VNet, DNS zones) | shared-services not applied yet — deploy order. |
| Dev plan: `failed to validate workspace_id` on `databricks_*` | Workspace doesn't exist yet — run the pass-1 `-target` apply first. |
| Locked out of workspace front-end after pass 2 | Applied the IP access list from an IP not in `allowed_ip_addresses`. |
| Cluster hangs at launch | Firewall egress allowlist missing a required Databricks control-plane endpoint. |
| PE exists but connections fail with public-IP resolution | Missing Private DNS zone **link** to the spoke VNet. |
