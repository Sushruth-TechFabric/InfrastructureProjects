# =============================================================================
# environments/dev-lab — ROOT CONFIG (Azure layer)  [ADR-0006]
# -----------------------------------------------------------------------------
# What this profile deliberately OMITS vs environments/dev (the ~$730/mo delta):
# hub firewall + NAT, VNet injection, all private endpoints + private DNS.
# What it KEEPS (every free security control):
#   - SCC / no_public_ip on the workspace
#   - secretless data access (Access Connector UAMI + narrow RBAC)
#   - workspace IP access list (workspace.tf)
#   - storage/Key Vault default-DENY firewalls with an explicit allowlist
#   - $150 budget with 50/80/100% notifications
# Trade-off, stated plainly: the data plane traverses PUBLIC endpoints, gated by
# firewall allowlists + Entra identity. That is NOT the client posture — the
# secure environments/dev root remains the reference implementation.
#
# KNOWN CAVEATS (details + fixes in README.md):
#   1. Two-phase apply: databricks-provider resources need the live workspace.
#      Fresh deploy: `terraform apply "-target=azurerm_databricks_workspace.this"`
#      first, then a full `terraform apply`.
#   2. Serverless needs account-level enablement; else enable_serverless=false.
#   3. Storage-credential RBAC propagation can lag a few minutes; a 403 on the
#      first full apply resolves by re-running apply.
#   4. Unity Catalog assumes the account's AUTO-ENABLED regional metastore; no
#      databricks_metastore is managed here (see uc.tf preflight note).
# =============================================================================

locals {
  common_tags = var.tags

  # Naming convention (API contract): {type}-{workload}-{env}-{region}-{instance}
  name_suffix = "${var.environment}-${var.region_abbrev}-${var.instance}"

  # Medallion layers + a dedicated container for UC MANAGED table storage:
  # auto-provisioned metastores have no metastore-level root, so the `lab`
  # catalog must bring its own managed-storage location (see uc.tf).
  filesystem_names = ["bronze", "silver", "gold", "catalog"]
}

# Current Entra tenant (for Key Vault). No secrets — just context.
data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Function-based resource groups
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "databricks" {
  name     = "rg-databricks-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "storage" {
  name     = "rg-storage-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "security" {
  name     = "rg-security-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Modules (same blueprints as the secure roots — only network exposure differs)
# ---------------------------------------------------------------------------
module "storage" {
  source = "../../modules/storage"

  resource_group_name  = azurerm_resource_group.storage.name
  location             = var.location
  storage_account_name = var.storage_account_name
  filesystem_names     = local.filesystem_names

  # ADR-0006 lab exposure: public endpoint ON, but default-DENY + allowlist.
  # Your IP gets in for browsing/uploads; Databricks compute gets in via a
  # resource-instance rule on the Access Connector (its managed-VNet IPs are
  # not allowlistable), authenticated as the UAMI — identity, not IP.
  public_network_access_enabled = true
  network_default_action        = "Deny"
  network_ip_rules              = var.allowed_ip_addresses
  network_resource_access_ids   = [module.identity.access_connector_id]

  tags = local.common_tags
}

module "key_vault" {
  source = "../../modules/key-vault"

  resource_group_name = azurerm_resource_group.security.name
  location            = var.location
  key_vault_name      = "kv-dbx-${local.name_suffix}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # Same lab exposure pattern as storage (trusted Azure services bypass covers
  # the Databricks side; your IP covers portal/CLI secret management).
  public_network_access_enabled = true
  network_default_action        = "Deny"
  network_ip_rules              = var.allowed_ip_addresses

  tags = local.common_tags
}

module "identity" {
  source = "../../modules/identity"

  resource_group_name         = azurerm_resource_group.security.name
  location                    = var.location
  user_assigned_identity_name = "id-dbx-connector-${local.name_suffix}"
  access_connector_name       = "dbac-dbx-${local.name_suffix}"

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Databricks workspace — INLINE, not modules/databricks-workspace
# ---------------------------------------------------------------------------
# The module's contract is VNet injection (subnets + NSG associations are
# required inputs). This profile has no VNet at all (Databricks managed VNet),
# so an inline resource with no network parameters is simpler and keeps the
# module's secure contract intact. SCC (no_public_ip) is kept — it is free.
resource "azurerm_databricks_workspace" "this" {
  name                        = "dbw-dbx-${local.name_suffix}"
  resource_group_name         = azurerm_resource_group.databricks.name
  location                    = var.location
  sku                         = "premium" # UC, IP access lists, serverless all need premium
  managed_resource_group_name = "rg-dbw-managed-${local.name_suffix}"

  # Front-end reachable over the internet, gated by Entra ID + the IP access
  # list in workspace.tf (same front-end posture as the secure build).
  public_network_access_enabled = true

  custom_parameters {
    no_public_ip = true # SCC: cluster nodes get no public IPs, outbound-only tunnel
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# RBAC — secretless data access (the core grant)
# ---------------------------------------------------------------------------
# The Access Connector's UAMI gets Storage Blob Data Contributor on this one
# account (narrowest scope, data-plane-only role). Unity Catalog's storage
# credential (uc.tf) then lets Databricks act AS this identity — no keys.
resource "azurerm_role_assignment" "connector_blob_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.identity.user_assigned_identity_principal_id
}

# ---------------------------------------------------------------------------
# Budget guardrail — the control that makes "$150/month" enforceable in code
# ---------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "lab" {
  name            = "budget-dbx-${local.name_suffix}-monthly"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  # Anchor to the first of the current month at creation time; ignore_changes
  # below stops the anchor from churning the resource on later applies.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  notification {
    enabled        = true
    threshold      = 80 # at 80%: stop scheduling new work (cost playbook, design doc §6)
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = var.budget_contact_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted" # early warning: on track to blow the month
    contact_emails = var.budget_contact_emails
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
