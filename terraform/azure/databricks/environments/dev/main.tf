# =============================================================================
# environments/dev — ROOT CONFIG (instantiate modules + cross-state wiring)
# -----------------------------------------------------------------------------
# main.tf across environments should look nearly identical — the differences
# live in each env's terraform.tfvars. This file:
#   1. resolves hub (shared-services) resources by NAME via data sources
#   2. creates function-based resource groups
#   3. instantiates the reusable modules
#   4. does the cross-state glue that isn't a reusable blueprint:
#      VNet peering, Private DNS zone links, private endpoints, RBAC
# =============================================================================

locals {
  # One tag map, applied everywhere. ManagedBy is always terraform.
  common_tags = var.tags

  # Naming convention: {type}-{workload}-{env}-{region}-{instance}. Workload = dbx.
  name_suffix = "${var.environment}-${var.region_abbrev}-${var.instance}"

  # Private DNS zones we must link + point private endpoints at. Keys are stable
  # short handles; values are the Azure-fixed zone names.
  dns_zones = {
    blob       = "privatelink.blob.core.windows.net"
    dfs        = "privatelink.dfs.core.windows.net"
    vault      = "privatelink.vaultcore.azure.net"
    databricks = "privatelink.azuredatabricks.net"
  }
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
# Current Entra tenant (for Key Vault). No secrets — just context.
data "azurerm_client_config" "current" {}

# Hub VNet (to peer with) — resolved by NAME, per the cross-state contract.
data "azurerm_virtual_network" "hub" {
  name                = var.hub_vnet_name
  resource_group_name = var.hub_resource_group_name
}

# Hub firewall — we need its private IP as the forced-tunneling next hop.
data "azurerm_firewall" "hub" {
  name                = var.hub_firewall_name
  resource_group_name = var.hub_resource_group_name
}

# The four Private DNS zones created in shared-services — resolved by name.
data "azurerm_private_dns_zone" "zones" {
  for_each            = local.dns_zones
  name                = each.value
  resource_group_name = var.hub_resource_group_name
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

  vnet_name          = "vnet-dbx-${local.name_suffix}"
  vnet_address_space = var.spoke_vnet_address_space

  host_subnet_name        = "snet-dbx-host-${var.environment}"
  host_subnet_prefix      = var.host_subnet_prefix
  container_subnet_name   = "snet-dbx-container-${var.environment}"
  container_subnet_prefix = var.container_subnet_prefix
  pe_subnet_name          = "snet-dbx-pe-${var.environment}"
  pe_subnet_prefix        = var.pe_subnet_prefix

  # Forced-tunneling next hop = hub firewall private IP (resolved by data source).
  firewall_private_ip = data.azurerm_firewall.hub.ip_configuration[0].private_ip_address

  tags = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  resource_group_name  = azurerm_resource_group.storage.name
  location             = var.location
  storage_account_name = var.storage_account_name
  filesystem_names     = ["bronze", "silver", "gold"]

  tags = local.common_tags
}

module "key_vault" {
  source = "../../modules/key-vault"

  resource_group_name = azurerm_resource_group.security.name
  location            = var.location
  key_vault_name      = "kv-dbx-${local.name_suffix}"
  tenant_id           = data.azurerm_client_config.current.tenant_id

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

module "databricks_workspace" {
  source = "../../modules/databricks-workspace"

  resource_group_name         = azurerm_resource_group.databricks.name
  location                    = var.location
  workspace_name              = "dbw-dbx-${local.name_suffix}"
  managed_resource_group_name = "rg-dbw-managed-${local.name_suffix}"

  virtual_network_id    = module.networking.vnet_id
  host_subnet_name      = module.networking.host_subnet_name
  container_subnet_name = module.networking.container_subnet_name

  host_subnet_nsg_association_id      = module.networking.host_subnet_nsg_association_id
  container_subnet_nsg_association_id = module.networking.container_subnet_nsg_association_id

  tags = local.common_tags
}

# ===========================================================================
# CROSS-STATE WIRING (glue that depends on both spoke and hub)
# ===========================================================================

# ---- VNet peering (both directions, created from the spoke's config) -------
# The spoke owns this relationship: it can reference both its own VNet (module
# output) and the hub VNet (data source), so it creates both peering halves.
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-dbx-${var.environment}-to-hub"
  resource_group_name       = azurerm_resource_group.networking.name
  virtual_network_name      = module.networking.vnet_name
  remote_virtual_network_id = data.azurerm_virtual_network.hub.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-dbx-${var.environment}"
  resource_group_name       = var.hub_resource_group_name
  virtual_network_name      = data.azurerm_virtual_network.hub.name
  remote_virtual_network_id = module.networking.vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# ---- Private DNS zone links: link each hub zone to the dev spoke VNet -------
# THE classic silent failure is forgetting this: the private endpoint exists,
# public access is off, but without the zone link the cluster resolves the old
# PUBLIC ip and the connection fails. One link per zone, into the hub RG.
resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each = local.dns_zones

  name                  = "link-${each.key}-dbx-${var.environment}"
  resource_group_name   = var.hub_resource_group_name
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
  name                = "pep-blob-dbx-${local.name_suffix}"
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
  name                = "pep-dfs-dbx-${local.name_suffix}"
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
  name                = "pep-kv-dbx-${local.name_suffix}"
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
  name                = "pep-dbx-backend-${local.name_suffix}"
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
