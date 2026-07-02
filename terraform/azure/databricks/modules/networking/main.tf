# =============================================================================
# modules/networking — SPOKE VNET FOR DATABRICKS VNET INJECTION
# -----------------------------------------------------------------------------
# This module builds ONLY the spoke's internal network:
#   - the VNet
#   - two subnets DELEGATED to Databricks (host + container) — "VNet injection"
#   - a private-endpoint subnet (kept separate from the delegated ones)
#   - an NSG per subnet (Databricks manages the rules inside via its network
#     intent policy; we just attach a placeholder NSG so the subnet has one)
#   - a route table that forces ALL egress (0.0.0.0/0) to the hub firewall
#
# Cross-state wiring that DEPENDS on the hub (VNet peering, Private DNS zone
# links, private endpoints) lives in the environment root, not here, because it
# is environment-specific glue rather than a reusable blueprint.
# =============================================================================

# ---------------------------------------------------------------------------
# Spoke virtual network
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "spoke" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Host (public) subnet — DELEGATED to Databricks.
# "Delegation" hands subnet management to the Microsoft.Databricks/workspaces
# service so it can inject cluster NICs and enforce the network intent policy.
# Despite the name "public", with Secure Cluster Connectivity there is NO public
# IP — the name is just Databricks' historical label for the host subnet.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "host" {
  name                 = var.host_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [var.host_subnet_prefix]

  delegation {
    name = "databricks-host-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Container (private) subnet — DELEGATED to Databricks (same delegation).
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "container" {
  name                 = var.container_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [var.container_subnet_prefix]

  delegation {
    name = "databricks-container-delegation"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# ---------------------------------------------------------------------------
# Private-endpoint subnet — NOT delegated. Holds the private endpoints for
# ADLS, Key Vault, and the Databricks back-end Private Link.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "private_endpoint" {
  name                 = var.pe_subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [var.pe_subnet_prefix]
}

# ---------------------------------------------------------------------------
# NSGs on the two delegated subnets.
# Databricks REQUIRES an NSG on each delegated subnet and then auto-creates and
# protects the rules it needs via the "network intent policy". We deliberately
# add NO custom rules — overriding Databricks' managed rules breaks the
# workspace. The NSG is essentially a mandatory anchor point.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "host" {
  # Strip the leading "snet-" so we get e.g. nsg-dbx-host-dev, not nsg-snet-dbx-host-dev.
  name                = "nsg-${replace(var.host_subnet_name, "snet-", "")}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "container" {
  name                = "nsg-${replace(var.container_subnet_name, "snet-", "")}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "host" {
  subnet_id                 = azurerm_subnet.host.id
  network_security_group_id = azurerm_network_security_group.host.id
}

resource "azurerm_subnet_network_security_group_association" "container" {
  subnet_id                 = azurerm_subnet.container.id
  network_security_group_id = azurerm_network_security_group.container.id
}

# ---------------------------------------------------------------------------
# Forced tunneling.
# A route table sends 0.0.0.0/0 (all internet-bound traffic) to the hub
# firewall's PRIVATE IP as a "VirtualAppliance" next hop, so every egress packet
# is inspected against the firewall's allowlist. Associated to BOTH delegated
# subnets. (The firewall allowlist itself lives in shared-services.)
# ---------------------------------------------------------------------------
resource "azurerm_route_table" "spoke" {
  # Strip the leading "vnet-" so we get e.g. rt-dbx-dev-wus3-001, not rt-vnet-dbx-...
  name                = "rt-${replace(var.vnet_name, "vnet-", "")}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  route {
    name                   = "default-to-hub-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "host" {
  subnet_id      = azurerm_subnet.host.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "container" {
  subnet_id      = azurerm_subnet.container.id
  route_table_id = azurerm_route_table.spoke.id
}
