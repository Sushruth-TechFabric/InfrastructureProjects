# =============================================================================
# environments/dev — ROOT CONFIG (instantiate modules + cross-state wiring)
# -----------------------------------------------------------------------------
# main.tf across environments should look nearly identical — the differences
# live in each env's terraform.tfvars. This file:
#   1. resolves hub (shared-services) resources by NAME via data sources
#   2. creates function-based resource groups
#   3. instantiates the reusable modules
#   4. does the cross-state glue that isn't a reusable blueprint:
#      Private DNS zone links, private endpoints, RBAC
#
# Egress (ADR-0007): dev uses NAT Gateway + NSG allowlist egress, NOT the hub
# firewall — so there is no firewall data source, no forced-tunneling route,
# and no hub VNet peering here. The only hub dependency left is the four
# Private DNS zones. Re-adding `firewall_private_ip` to the networking module
# call (and the peering) restores the enterprise forced-tunneling posture.
# =============================================================================

locals {
  # One tag map, applied everywhere. ManagedBy is always terraform.
  common_tags = var.tags

  # Naming convention: {type}-{project}-{env}-{region}-{instance}. The project
  # token comes from var.project so these roots are reusable across projects.
  name_suffix = "${var.project}-${var.environment}-${var.region_abbrev}-${var.instance}"

  # The four function RGs by handle — the scopes resource_group_reader_groups
  # grants Reader on (see the RBAC section at the bottom).
  env_resource_group_ids = {
    networking = azurerm_resource_group.networking.id
    databricks = azurerm_resource_group.databricks.id
    storage    = azurerm_resource_group.storage.id
    security   = azurerm_resource_group.security.id
  }

  # Private DNS zones we must link + point private endpoints at. Keys are stable
  # short handles; values are the Azure-fixed zone names.
  dns_zones = {
    blob       = "privatelink.blob.core.windows.net"
    dfs        = "privatelink.dfs.core.windows.net"
    vault      = "privatelink.vaultcore.azure.net"
    databricks = "privatelink.azuredatabricks.net"
  }

  # E3 (2026-07-10 review): the three cross-state/naming lookups default to
  # null so a renamed project/region/instance doesn't silently point at the
  # WRONG hub/metastore/storage account. coalesce() falls back to deriving the
  # name from THIS root's own naming-convention inputs — byte-identical to the
  # old hardcoded defaults for every existing deployment (dbx/wus3/001), and
  # correct automatically for a differently-named one. An explicit
  # var.* value (e.g. hub deployed with different tokens than this spoke)
  # always wins.
  effective_hub_resource_group_name = coalesce(
    var.hub_resource_group_name,
    "rg-networking-${var.project}-shared-${var.region_abbrev}-${var.instance}",
  )
  effective_metastore_name = coalesce(
    var.metastore_name,
    "mst-${var.project}-shared-${var.region_abbrev}-${var.instance}",
  )
  effective_storage_account_name = coalesce(
    var.storage_account_name,
    "st${var.project}${var.environment}${var.region_abbrev}${var.instance}",
  )
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
# Current Entra tenant (for Key Vault). No secrets — just context.
data "azurerm_client_config" "current" {}

# The AzureDatabricks FIRST-PARTY service principal — the identity the
# Databricks CONTROL PLANE presents when it calls into our tenant. Key
# Vault-backed secret scope reads are performed AS this identity (clusters
# never talk to Key Vault directly), so it — not our users, not the access
# connector UAMI — needs the data-plane role granted below.
#
# Why the GUID is hardcoded: Microsoft owns this multi-tenant app registration,
# and a multi-tenant app's client id is a GLOBAL CONSTANT — the same value in
# every Entra tenant (like Microsoft Graph's 00000003-...-c000-...). There is
# nothing per-tenant to parameterize, and a display-name lookup would be WORSE:
# names aren't unique, so any app squatting on "AzureDatabricks" could hijack
# the grant. What IS tenant-specific is the local SP's object_id — which is
# exactly what this lookup resolves. The SP exists in any tenant that has ever
# created a Databricks workspace (Azure instantiates it on first use), so
# ordering is safe here: the workspace lives in this same state.
data "azuread_service_principal" "azure_databricks" {
  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}

# The four Private DNS zones created in shared-services — resolved by name.
# (The only hub dependency in NAT-egress mode; see the header note / ADR-0007.)
data "azurerm_private_dns_zone" "zones" {
  for_each            = local.dns_zones
  name                = each.value
  resource_group_name = local.effective_hub_resource_group_name
}

# ---------------------------------------------------------------------------
# Function-based resource groups (RBAC follows least privilege at the boundary)
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "networking" {
  name     = "rg-networking-${local.name_suffix}"
  location = var.location
  tags     = local.common_tags
}

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
# Modules
# ---------------------------------------------------------------------------
module "networking" {
  source = "../../modules/networking"

  resource_group_name = azurerm_resource_group.networking.name
  location            = var.location

  vnet_name          = "vnet-${local.name_suffix}"
  vnet_address_space = var.spoke_vnet_address_space

  host_subnet_name        = "snet-${var.project}-host-${var.environment}"
  host_subnet_prefix      = var.host_subnet_prefix
  container_subnet_name   = "snet-${var.project}-container-${var.environment}"
  container_subnet_prefix = var.container_subnet_prefix
  pe_subnet_name          = "snet-${var.project}-pe-${var.environment}"
  pe_subnet_prefix        = var.pe_subnet_prefix

  # Egress mode B (ADR-0007): NAT Gateway on the delegated subnets + NSG
  # service-tag allowlist. Swap for `firewall_private_ip = ...` to restore
  # forced tunneling through the hub firewall.
  enable_nat_gateway_egress = true

  tags = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  resource_group_name  = azurerm_resource_group.storage.name
  location             = var.location
  storage_account_name = local.effective_storage_account_name
  # `catalog` holds UC managed-table storage for the future dev catalog — the
  # metastore has no root storage, so each env owns its catalog's (ADR-0011).
  filesystem_names = ["bronze", "silver", "gold", "catalog"]

  tags = local.common_tags
}

module "key_vault" {
  source = "../../modules/key-vault"

  resource_group_name = azurerm_resource_group.security.name
  location            = var.location
  key_vault_name      = "kv-${local.name_suffix}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

  tags = local.common_tags
}

module "identity" {
  source = "../../modules/identity"

  resource_group_name         = azurerm_resource_group.security.name
  location                    = var.location
  user_assigned_identity_name = "id-connector-${local.name_suffix}"
  access_connector_name       = "dbac-${local.name_suffix}"

  tags = local.common_tags
}

module "databricks_workspace" {
  source = "../../modules/databricks-workspace"

  resource_group_name         = azurerm_resource_group.databricks.name
  location                    = var.location
  workspace_name              = "dbw-${local.name_suffix}"
  managed_resource_group_name = "rg-dbw-managed-${local.name_suffix}"

  virtual_network_id    = module.networking.vnet_id
  host_subnet_name      = module.networking.host_subnet_name
  container_subnet_name = module.networking.container_subnet_name

  host_subnet_nsg_association_id      = module.networking.host_subnet_nsg_association_id
  container_subnet_nsg_association_id = module.networking.container_subnet_nsg_association_id

  tags = local.common_tags
}

module "workspace_access" {
  source = "../../modules/workspace-access"

  # The module talks to the ACCOUNT-level API — pass the aliased provider
  # explicitly (declared as a configuration_alias in the module).
  providers = {
    databricks.account = databricks.account
  }

  project      = var.project
  environment  = var.environment
  workspace_id = module.databricks_workspace.workspace_resource_id # numeric id, not the ARM id
  groups       = var.identity_groups

  # databricks_mws_permission_assignment (inside this module) requires the
  # workspace to already be identity-federated (UC-attached) — see the module
  # header comment. uc.tf's metastore assignment always exists in config (no
  # conditional/import-gate), so this reference is safe on every apply. Without
  # it, this module and the metastore assignment have no edge between them and
  # Terraform may apply them concurrently: harmless on accounts that
  # auto-attach a default metastore, but a hard failure ("workspace not
  # enabled for identity federation") on any account that does not.
  depends_on = [databricks_metastore_assignment.this]
}

# ===========================================================================
# CROSS-STATE WIRING (glue that depends on both spoke and hub)
# ===========================================================================

# ---- VNet peering: NONE in NAT-egress mode (ADR-0007) ----------------------
# Peering existed solely so the forced-tunneling UDR could reach the hub
# firewall. With NAT egress there is no hub next-hop, and Private DNS zone
# links do NOT require peering — so the spoke stands alone. Restore both
# peering halves (spoke→hub and hub→spoke) if the firewall mode returns.

# ---- Private DNS zone links: link each hub zone to the dev spoke VNet -------
# THE classic silent failure is forgetting this: the private endpoint exists,
# public access is off, but without the zone link the cluster resolves the old
# PUBLIC ip and the connection fails. One link per zone, into the hub RG.
resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each = local.dns_zones

  name                  = "link-${each.key}-${var.project}-${var.environment}"
  resource_group_name   = local.effective_hub_resource_group_name
  private_dns_zone_name = data.azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = module.networking.vnet_id
  registration_enabled  = false

  tags = local.common_tags
}

# ---- Private endpoints (the PE + DNS-zone-group pattern, once per service) ---
# Each PE lands in the spoke's PE subnet and registers an A record in the matching
# hub DNS zone via its private_dns_zone_group.

# ADLS Gen2 — blob sub-resource
resource "azurerm_private_endpoint" "adls_blob" {
  name                = "pep-blob-${local.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.networking.name
  subnet_id           = module.networking.private_endpoint_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = module.storage.storage_account_id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-blob"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.zones["blob"].id]
  }
}

# ADLS Gen2 — dfs (Data Lake) sub-resource
resource "azurerm_private_endpoint" "adls_dfs" {
  name                = "pep-dfs-${local.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.networking.name
  subnet_id           = module.networking.private_endpoint_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-dfs"
    private_connection_resource_id = module.storage.storage_account_id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-dfs"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.zones["dfs"].id]
  }
}

# Key Vault — vault sub-resource
resource "azurerm_private_endpoint" "key_vault" {
  name                = "pep-kv-${local.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.networking.name
  subnet_id           = module.networking.private_endpoint_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = module.key_vault.key_vault_id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-vault"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.zones["vault"].id]
  }
}

# Databricks — back-end Private Link (databricks_ui_api sub-resource)
# This is the private path from the compute plane (clusters) to the control
# plane / SCC relay. The front-end stays public (identity-gated); only the
# BACK-END is private.
resource "azurerm_private_endpoint" "databricks_backend" {
  name                = "pep-dbw-backend-${local.name_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.networking.name
  subnet_id           = module.networking.private_endpoint_subnet_id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-dbx-uiapi"
    private_connection_resource_id = module.databricks_workspace.workspace_id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dzg-databricks"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.zones["databricks"].id]
  }
}

# ===========================================================================
# RBAC — secretless data access (the core grant)
# ===========================================================================
# The Access Connector's user-assigned identity gets Storage Blob Data
# Contributor on the ADLS account. Narrowest scope (this one account), most
# specific built-in role (data-plane only, NOT Contributor/Owner). This is what
# makes data access secretless — Databricks authenticates AS this identity.
resource "azurerm_role_assignment" "connector_blob_contributor" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.identity.user_assigned_identity_principal_id
}

# ---------------------------------------------------------------------------
# RBAC — Key Vault data plane (the vault is RBAC-authorized, so without these
# the KV-backed secret scope applies cleanly but every read 403s at runtime)
# ---------------------------------------------------------------------------
# dbutils.secrets.get() against the KV-backed scope is a two-layer check:
#   1. Databricks side — the scope's READ ACLs (workspace-permissions.tf)
#      decide WHO may ask for a secret.
#   2. Azure side — the control plane then fetches it from Key Vault AS the
#      AzureDatabricks first-party SP; THIS grant is what lets that fetch
#      succeed. Without it the scope + ACLs still apply cleanly, but every
#      read 403s at runtime.
# Secrets User = read-only on secret VALUES, scoped to this one vault —
# narrowest built-in role that satisfies layer 2 (rule 10). Note the
# principal is the tenant-local object_id resolved by the data source above,
# never the global client id (role assignments take object ids).
resource "azurerm_role_assignment" "databricks_kv_secrets_user" {
  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azuread_service_principal.azure_databricks.object_id
}

# Secret AUTHORING: who may create/update secret values in the vault. Groups
# only (AGENTS.md rule 10), driven by tfvars like every other grant matrix.
# Secrets Officer covers secrets only — no keys, certificates, or vault config.
resource "azurerm_role_assignment" "kv_secrets_officer" {
  for_each = toset(var.key_vault_secrets_officer_groups)

  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = module.workspace_access.group_object_ids[each.value]
}

# Human Azure-plane visibility (ADR-0008 seam, now wired): Reader on each of
# the four function RGs per group. Reader ONLY — data-plane access is governed
# by Unity Catalog (rule 7); a direct Storage Blob Data * grant here would
# bypass it, so none is offered.
resource "azurerm_role_assignment" "group_rg_reader" {
  for_each = {
    for pair in setproduct(var.resource_group_reader_groups, keys(local.env_resource_group_ids)) :
    "${pair[0]}-${pair[1]}" => pair
  }

  scope                = local.env_resource_group_ids[each.value[1]]
  role_definition_name = "Reader"
  principal_id         = module.workspace_access.group_object_ids[each.value[0]]
}
