# =============================================================================
# shared-services — HUB (deploy-once, own state)
# -----------------------------------------------------------------------------
# The hub holds the network services SHARED by every spoke/environment:
#   - Hub VNet + AzureFirewallSubnet (always)
#   - The four Private DNS zones for private endpoints (always)
#   - The UC metastore (account-level, one per region — lives in uc.tf, ADR-0011)
#   - OPTIONAL (var.deploy_firewall, default false — ADR-0007):
#       Azure Firewall (egress inspection + allowlist) — NON-ZONAL (see NAT)
#       NAT Gateway attached to the firewall subnet (stable, scalable egress IP)
#
# ADR-0007: dev egresses via its own spoke NAT Gateway + NSG allowlist, so the
# firewall chain (~$920/mo idle) is not deployed by default. Set
# deploy_firewall = true to restore the enterprise forced-tunneling reference
# (and re-add the firewall wiring in the spoke roots).
#
# Written inline (not as a module): it is a single, deploy-once instance, so a
# reusable blueprint would add indirection without payoff. Spokes reference these
# by NAME via Azure data sources (the cross-state contract), so the NAMES here
# are load-bearing — keep them on-convention.
# =============================================================================

locals {
  # Naming: {type}-{project}-{env}-{region}-{instance}; env token is "shared"
  # for the hub. Spokes resolve these BY NAME, so the same project/region/
  # instance values must be used in every spoke root (the cross-state contract).
  name_suffix = "${var.project}-shared-${var.region_abbrev}-${var.instance}"

  hub_rg_name    = "rg-networking-${local.name_suffix}"
  hub_vnet_name  = "vnet-hub-${local.name_suffix}"
  firewall_name  = "afw-hub-${local.name_suffix}"
  fw_policy_name = "afwp-hub-${local.name_suffix}"
  fw_pip_name    = "pip-afw-${local.name_suffix}"
  nat_name       = "ng-hub-${local.name_suffix}"
  nat_pip_name   = "pip-ng-${local.name_suffix}"

  # Private DNS zones required for the platform's private endpoints. The zone
  # NAME is fixed by Azure per service — these exact strings are what make
  # private-endpoint name resolution work.
  private_dns_zones = [
    "privatelink.blob.core.windows.net", # ADLS Gen2 blob
    "privatelink.dfs.core.windows.net",  # ADLS Gen2 dfs (Data Lake)
    "privatelink.vaultcore.azure.net",   # Key Vault
    "privatelink.azuredatabricks.net",   # Databricks back-end Private Link
  ]
}

# ---------------------------------------------------------------------------
# Hub resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "hub" {
  name     = local.hub_rg_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Hub VNet + AzureFirewallSubnet (the subnet NAME must be exactly this).
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = local.hub_vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = var.hub_vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.firewall_subnet_prefix]
}

# ---------------------------------------------------------------------------
# OPTIONAL FIREWALL CHAIN (var.deploy_firewall — ADR-0007).
# Everything from here to the rule collection group inclusive is created only
# when deploy_firewall = true.
#
# NAT Gateway integrated with the firewall subnet.
# WHY: gives the firewall a stable, high-scale outbound public IP (64,512 SNAT
# ports/IP vs the firewall's own 2,496). This is the Microsoft-documented
# Firewall+NAT pattern (associate NAT gateway directly to AzureFirewallSubnet).
# CONSTRAINT (ADR-0004): the firewall MUST be non-zonal — NAT Gateway cannot back
# a zone-redundant firewall. Hence no `zones` on the firewall or these IPs. This
# is a single-AZ SPOF, accepted per the architecture doc's resilience deferral.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  count = var.deploy_firewall ? 1 : 0

  name                = local.nat_pip_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = local.nat_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "hub" {
  count = var.deploy_firewall ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.hub[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "firewall" {
  count = var.deploy_firewall ? 1 : 0

  subnet_id      = azurerm_subnet.firewall.id
  nat_gateway_id = azurerm_nat_gateway.hub[0].id
}

# ---------------------------------------------------------------------------
# Azure Firewall + policy. Non-zonal (no `zones`) to satisfy the NAT constraint.
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "firewall" {
  count = var.deploy_firewall ? 1 : 0

  name                = local.fw_pip_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = local.fw_policy_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "hub" {
  count = var.deploy_firewall ? 1 : 0

  name                = local.firewall_name
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub[0].id
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  # NOTE: no `zones` argument on purpose (non-zonal, see NAT constraint above).

  # The subnet must have the NAT gateway attached before the firewall claims the
  # subnet, otherwise the association can fail.
  depends_on = [azurerm_subnet_nat_gateway_association.firewall]
}

# ---------------------------------------------------------------------------
# Egress allowlist.
# Databricks clusters SILENTLY FAIL to launch if the firewall does not permit
# the required control-plane endpoints. This is a STARTER set using service tags;
# you MUST reconcile it against the current region-specific Databricks address
# list from Microsoft Learn before relying on it.
# TODO(region-endpoints): verify SCC relay / webapp / metastore / artifact IPs.
# ---------------------------------------------------------------------------
resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  count = var.deploy_firewall ? 1 : 0

  name               = "rcg-egress-allowlist"
  firewall_policy_id = azurerm_firewall_policy.hub[0].id
  priority           = 200

  network_rule_collection {
    name     = "allow-databricks-controlplane"
    priority = 100
    action   = "Allow"

    rule {
      name              = "databricks-and-azure-services"
      protocols         = ["TCP"]
      source_addresses  = ["10.0.0.0/8"] # spoke ranges; tighten per environment
      destination_ports = ["443", "3306", "8443-8451"]
      destination_addresses = [
        "AzureDatabricks",          # Databricks control plane (service tag)
        "AzureActiveDirectory",     # Entra ID auth
        "Storage.${var.location}",  # regional storage (artifacts, logs, DBFS)
        "EventHub.${var.location}", # cluster/audit log delivery
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Private DNS zones (one per PaaS service). VNet LINKS to each spoke are created
# in that spoke's environment root (the env owns its VNet), so we create only the
# zones here. for_each over a set so the list is order-insensitive.
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each            = toset(local.private_dns_zones)
  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.tags
}
