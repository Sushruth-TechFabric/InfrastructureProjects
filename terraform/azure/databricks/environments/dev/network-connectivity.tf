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
# approval machinery (the azapi list data sources + azapi_update_resource
# approvals) is GATED behind var.ncc_approval_enabled (default false), because on
# a greenfield apply the storage / Key Vault ids feeding parent_id are unknown at
# plan -> the data reads defer -> their derived for_each keys are unknown -> hard
# plan error. Gate false on apply #1, true on apply #2 (ADR-0012 amendment):
#   apply #1 (ncc_approval_enabled = false) -> NCC + rules + binding created;
#            connections show PENDING; no approval attempted
#   apply #2 (ncc_approval_enabled = true)  -> the list data sources read the
#            PENDING connections and azapi approves ONLY this NCC's own
#            endpoints -> ESTABLISHED
# Confirm with `terraform output serverless_pe_connection_state`. See the
# deploy-dev runbook "serverless private connectivity" step and ADR-0012.
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
# Key Vault (vault): dev's secret scope IS Key Vault-backed (workspace-config.tf
# keyvault_metadata), but that scope is read by the Databricks CONTROL plane, not
# the serverless plane — so serverless does not traverse this rule today. It is
# included for future serverless model-serving secret access — a PRIVATE path
# either way; KV public access stays disabled regardless (ADR-0012).
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

# Two-phase gate for the owner-side approval machinery below. Declared here
# (co-located with the resources it governs, per the catalogs.tf/lakebase.tf
# precedent) rather than in variables.tf. Leave false for the first (infra)
# apply — it keeps the azapi list data sources and approvals out of the graph so
# unknown storage/KV ids do not fail the greenfield plan (T1). Flip true in
# terraform.tfvars for the second apply, once Databricks has raised the PENDING
# connections, to approve THIS NCC's endpoints (ADR-0012 amendment).
variable "ncc_approval_enabled" {
  type        = bool
  description = "Enable the owner-side approval of this NCC's Databricks-raised private endpoint connections (azapi). Two-phase apply: false on the first/infra apply (avoids the greenfield unknown-for_each plan failure), true on the second apply once the connections are Pending. Default off."
  default     = false
}

# ---------------------------------------------------------------------------
# Owner-side approval of the Databricks-raised connections (azapi).
# ---------------------------------------------------------------------------
# GATED behind var.ncc_approval_enabled (default false) — the two-phase apply:
#   * GREENFIELD SAFETY (T1): with the gate false the list data sources and the
#     approvals leave the graph entirely, so a first apply — where
#     module.storage / module.key_vault ids are still unknown at plan and would
#     otherwise defer the data reads into an UNKNOWN for_each ("Invalid for_each
#     argument") — plans and applies cleanly. Flip the gate true for apply #2,
#     once storage/KV exist and Databricks has raised the PENDING connections.
#   * SECURITY (T2): we approve ONLY connections whose name matches one of THIS
#     NCC's own private endpoint rules. databricks_mws_ncc_private_endpoint_rule
#     exports endpoint_name, and Databricks names the managed PE connection it
#     raises on the target == that endpoint_name; so an unrelated or adversarial
#     Pending connection on the storage/KV resource id is NEVER in our
#     endpoint-name allowlist and is never approved (the old status-only filter
#     approved any Pending — the blocker).
#   * NO CHURN: for_each is driven off the connection set and keyed on the STABLE
#     connection name (== the rule's endpoint_name), not on transient Pending
#     status, so an already-Approved connection stays in the map on later runs
#     (idempotent no-op PATCH) instead of dropping out and planning as a destroy.
data "azapi_resource_list" "storage_pe" {
  count                  = var.ncc_approval_enabled ? 1 : 0
  type                   = "Microsoft.Storage/storageAccounts/privateEndpointConnections@2023-05-01"
  parent_id              = module.storage.storage_account_id
  response_export_values = ["*"]
}

data "azapi_resource_list" "vault_pe" {
  count                  = var.ncc_approval_enabled ? 1 : 0
  type                   = "Microsoft.KeyVault/vaults/privateEndpointConnections@2023-07-01"
  parent_id              = module.key_vault.key_vault_id
  response_export_values = ["*"]
}

locals {
  # THIS NCC's own endpoint names, per target. The managed PE connection
  # Databricks raises on the target is named == the rule's exported
  # endpoint_name, so this is the allowlist we approve against.
  storage_endpoint_names = [
    for k, r in databricks_mws_ncc_private_endpoint_rule.this :
    r.endpoint_name if contains(["blob", "dfs"], local.ncc_pe_rules[k].group_id)
  ]
  vault_endpoint_names = [
    for k, r in databricks_mws_ncc_private_endpoint_rule.this :
    r.endpoint_name if local.ncc_pe_rules[k].group_id == "vault"
  ]

  # Live connections on each target (connection name => resource id). Empty when
  # the gate is off (count = 0) — which makes the approval maps below known-empty
  # (the for_each iterates this set), so apply #1 never hits an unknown for_each.
  storage_conns = {
    for c in try(data.azapi_resource_list.storage_pe[0].output.value, []) :
    c.name => c.id
  }
  vault_conns = {
    for c in try(data.azapi_resource_list.vault_pe[0].output.value, []) :
    c.name => c.id
  }

  # connection name => connection id, restricted to OUR endpoints. Driven off the
  # connection set and keyed by the stable connection name (== endpoint_name), so
  # the map is known-empty on apply #1 and an entry never churns (drops out and
  # plans as a destroy) as its connection moves Pending -> Approved.
  storage_approvals = {
    for name, id in local.storage_conns :
    name => id if contains(local.storage_endpoint_names, name)
  }
  vault_approvals = {
    for name, id in local.vault_conns :
    name => id if contains(local.vault_endpoint_names, name)
  }
}

resource "azapi_update_resource" "approve_storage" {
  for_each = local.storage_approvals

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

  # Only meaningful once the rules exist and their connections are present; the
  # for_each already gates that (empty on apply #1 / when ncc_approval_enabled
  # is false).
  depends_on = [databricks_mws_ncc_private_endpoint_rule.this]
}

resource "azapi_update_resource" "approve_vault" {
  for_each = local.vault_approvals

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
