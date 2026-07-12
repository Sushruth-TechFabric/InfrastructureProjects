# =============================================================================
# environments/dev — SERVERLESS NETWORK CONNECTIVITY (NCC) — ADR-0012
# -----------------------------------------------------------------------------
# Serverless Databricks features (serverless SQL, model serving, vector search,
# Lakebase) run in a Databricks-MANAGED plane, NOT in our VNet-injected spoke.
# So the spoke NSGs, NAT egress, and back-end Private Link (pep-dbw-backend-*)
# do NOT cover them, and serverless compute has no path to our PE-only ADLS /
# Key Vault (public access DISABLED). This file closes that gap WITHOUT widening
# any public access: it stands up a Databricks account-level Network
# Connectivity Config (NCC) whose private endpoint rules make Databricks raise
# managed private endpoints from the serverless plane to our data-plane
# resources. Storage and Key Vault stay `Deny` / private throughout.
#
# STATE BOUNDARY (why here, not shared-services): unlike the UC metastore (one
# per region — a forced singleton, hence shared-services/ADR-0011), an account
# may hold MANY NCCs, and these rules embed DEV-OWNED resource ids (dev's ADLS,
# dev's KV). Keeping them in the env root keeps dev's data path inside dev's
# state boundary (the ADR-0011 principle). The NCC->workspace binding is
# workspace-specific, the same shape ADR-0008 used for permission assignments.
# One NCC per environment; staging/prod get their own copy of this file.
#
# TWO-PHASE APPLY (expected, not a bug): Databricks raises the private endpoint
# connection from its managed subscription, so it lands PENDING on our resource
# and we (the owner) must APPROVE it. azurerm has no resource for owner-side
# approval of a third-party-initiated connection, so azapi does it below. The
# approval data sources read CURRENT Azure state at plan time, so:
#   apply #1 -> NCC + rules + binding created; connections show PENDING
#   apply #2 -> the list data sources now see the PENDING connections and
#               azapi approves them -> ESTABLISHED
# Confirm with `terraform output serverless_pe_connection_state`. See the
# deploy-dev runbook "serverless private connectivity" step.
# =============================================================================

# ---------------------------------------------------------------------------
# NCC — account object, region-scoped (must match the workspace region).
# ---------------------------------------------------------------------------
# Name regex ^[0-9a-zA-Z-_]{3,30}$ ; "ncc-dbx-dev-wus3-001" (20 chars) is valid.
# Both name and region are ForceNew.
resource "databricks_mws_network_connectivity_config" "this" {
  provider = databricks.account

  name   = "ncc-${local.name_suffix}"
  region = var.location
}

# Bind the NCC to the dev workspace so ITS serverless compute uses these rules.
# workspace_id is the NUMERIC id (workspace_resource_id) — same value the UC
# metastore assignment uses, NOT the ARM resource id (workspace_id).
resource "databricks_mws_ncc_binding" "this" {
  provider = databricks.account

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  workspace_id                   = module.databricks_workspace.workspace_resource_id
}

# ---------------------------------------------------------------------------
# Private endpoint rules — one per subresource.
# ---------------------------------------------------------------------------
# group_id: blob + dfs for ADLS Gen2; vault for Key Vault. Each rule makes
# Databricks create a managed private endpoint that raises a PENDING connection
# on the target resource (approved by azapi below).
#
# Key Vault (vault): serverless does not reach KV today (dev uses
# Databricks-backed secret scopes, not KV-backed), but the rule is included for
# future model-serving secret access — a PRIVATE path either way; KV public
# access stays disabled regardless (ADR-0012).
locals {
  ncc_pe_rules = {
    blob  = { resource_id = module.storage.storage_account_id, group_id = "blob" }
    dfs   = { resource_id = module.storage.storage_account_id, group_id = "dfs" }
    vault = { resource_id = module.key_vault.key_vault_id, group_id = "vault" }
  }
}

resource "databricks_mws_ncc_private_endpoint_rule" "this" {
  provider = databricks.account
  for_each = local.ncc_pe_rules

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  resource_id                    = each.value.resource_id
  group_id                       = each.value.group_id
}

# ---------------------------------------------------------------------------
# Owner-side approval of the Databricks-raised connections (azapi).
# ---------------------------------------------------------------------------
# NO depends_on on the list data sources: they must read CURRENT Azure state at
# plan time so their for_each keys are always known (an unknown for_each errors
# at plan). That is what makes this a two-phase apply — see the header. We only
# approve connections in `Pending`: our own spoke private endpoints
# (pep-blob/dfs/vault-*) are same-owner and already Approved, so they are never
# matched here.
data "azapi_resource_list" "storage_pe" {
  type                   = "Microsoft.Storage/storageAccounts/privateEndpointConnections@2023-05-01"
  parent_id              = module.storage.storage_account_id
  response_export_values = ["*"]
}

data "azapi_resource_list" "vault_pe" {
  type                   = "Microsoft.KeyVault/vaults/privateEndpointConnections@2023-07-01"
  parent_id              = module.key_vault.key_vault_id
  response_export_values = ["*"]
}

locals {
  # name => connection resource id, restricted to Pending (Databricks-raised).
  storage_pending = {
    for c in try(data.azapi_resource_list.storage_pe.output.value, []) :
    c.name => c.id
    if try(c.properties.privateLinkServiceConnectionState.status, "") == "Pending"
  }
  vault_pending = {
    for c in try(data.azapi_resource_list.vault_pe.output.value, []) :
    c.name => c.id
    if try(c.properties.privateLinkServiceConnectionState.status, "") == "Pending"
  }
}

resource "azapi_update_resource" "approve_storage" {
  for_each = local.storage_pending

  type        = "Microsoft.Storage/storageAccounts/privateEndpointConnections@2023-05-01"
  resource_id = each.value

  body = {
    properties = {
      privateLinkServiceConnectionState = {
        status      = "Approved"
        description = "Approved by Terraform — dev serverless NCC (ADR-0012)."
      }
    }
  }

  # Only meaningful once the rules exist and their connections are Pending; the
  # for_each already gates that (empty on apply #1).
  depends_on = [databricks_mws_ncc_private_endpoint_rule.this]
}

resource "azapi_update_resource" "approve_vault" {
  for_each = local.vault_pending

  type        = "Microsoft.KeyVault/vaults/privateEndpointConnections@2023-07-01"
  resource_id = each.value

  body = {
    properties = {
      privateLinkServiceConnectionState = {
        status      = "Approved"
        description = "Approved by Terraform — dev serverless NCC (ADR-0012)."
      }
    }
  }

  depends_on = [databricks_mws_ncc_private_endpoint_rule.this]
}
