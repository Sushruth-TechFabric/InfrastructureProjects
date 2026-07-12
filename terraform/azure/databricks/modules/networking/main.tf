# =============================================================================
# modules/networking — SPOKE VNET FOR DATABRICKS VNET INJECTION
# -----------------------------------------------------------------------------
# This module builds ONLY the spoke's internal network:
#   - the VNet
#   - two subnets DELEGATED to Databricks (host + container) — "VNet injection"
#   - a private-endpoint subnet (kept separate from the delegated ones)
#   - an NSG per subnet (Databricks manages the required rules inside via its
#     network intent policy; we add egress-allowlist rules only in NAT mode)
#   - ONE of two egress paths for the delegated subnets (ADR-0007):
#       a) firewall mode  — route table forcing 0.0.0.0/0 to a hub firewall
#       b) NAT mode       — NAT Gateway on both subnets + NSG service-tag
#                           allowlist with a deny-Internet catch-all
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
# protects the rules it needs via the "network intent policy". We never touch
# those managed rules (overriding them breaks the workspace), which is also why
# the egress rules further down are standalone azurerm_network_security_rule
# resources: inline security_rule blocks would make Terraform authoritative
# over the whole rule set and delete the Databricks-managed rules on refresh.
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
# EGRESS MODE A — forced tunneling (firewall mode).
# A route table sends 0.0.0.0/0 (all internet-bound traffic) to the hub
# firewall's PRIVATE IP as a "VirtualAppliance" next hop, so every egress packet
# is inspected against the firewall's allowlist. Associated to BOTH delegated
# subnets. (The firewall allowlist itself lives in shared-services.)
# Created only when the caller supplies firewall_private_ip.
# ---------------------------------------------------------------------------
resource "azurerm_route_table" "spoke" {
  count = var.firewall_private_ip != null ? 1 : 0

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
  count = var.firewall_private_ip != null ? 1 : 0

  subnet_id      = azurerm_subnet.host.id
  route_table_id = azurerm_route_table.spoke[0].id
}

resource "azurerm_subnet_route_table_association" "container" {
  count = var.firewall_private_ip != null ? 1 : 0

  subnet_id      = azurerm_subnet.container.id
  route_table_id = azurerm_route_table.spoke[0].id
}

# ---------------------------------------------------------------------------
# EGRESS MODE B — NAT Gateway + NSG service-tag allowlist (ADR-0007).
# A NAT Gateway on both delegated subnets gives clusters a stable, auditable
# outbound public IP (also the required explicit egress path now that Azure has
# retired default outbound access for new subnets). Egress CONTROL comes from
# NSG outbound rules: allow the documented Databricks control-plane service
# tags, then deny everything else to Internet. Coarser than a firewall (a
# service tag admits the whole regional service, not a specific FQDN) — that
# trade-off is recorded in ADR-0007.
# ---------------------------------------------------------------------------
locals {
  # Documented outbound requirements for VNet-injected workspaces with SCC.
  # Mirrors the rules the Databricks network intent policy manages, made
  # explicit so the deny-Internet catch-all below never races ahead of them.
  nat_egress_allow_rules = {
    databricks-control-plane = {
      priority = 100
      ports    = ["443", "3306", "8443-8451"]
      dest     = "AzureDatabricks"
    }
    entra-id-auth = {
      priority = 110
      ports    = ["443"]
      dest     = "AzureActiveDirectory"
    }
    regional-storage = {
      priority = 120
      ports    = ["443"]
      dest     = "Storage.${var.location}"
    }
    legacy-hive-metastore = {
      priority = 130
      ports    = ["3306"]
      dest     = "Sql.${var.location}"
    }
    log-delivery-eventhub = {
      priority = 140
      ports    = ["9093"]
      dest     = "EventHub.${var.location}"
    }
  }

  # rule-key × NSG matrix so one resource covers both delegated subnets.
  nat_egress_rule_matrix = var.enable_nat_gateway_egress ? {
    for pair in setproduct(keys(local.nat_egress_allow_rules), ["host", "container"]) :
    "${pair[0]}-${pair[1]}" => {
      rule = local.nat_egress_allow_rules[pair[0]]
      key  = pair[0]
      nsg  = pair[1]
    }
  } : {}

  nat_nsg_names = {
    host      = azurerm_network_security_group.host.name
    container = azurerm_network_security_group.container.name
  }
}

resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway_egress ? 1 : 0

  # Strip the leading "vnet-" so we get e.g. pip-ng-dbx-dev-wus3-001.
  name                = "pip-ng-${replace(var.vnet_name, "vnet-", "")}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "spoke" {
  count = var.enable_nat_gateway_egress ? 1 : 0

  name                = "ng-${replace(var.vnet_name, "vnet-", "")}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "spoke" {
  count = var.enable_nat_gateway_egress ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.spoke[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "host" {
  count = var.enable_nat_gateway_egress ? 1 : 0

  subnet_id      = azurerm_subnet.host.id
  nat_gateway_id = azurerm_nat_gateway.spoke[0].id
}

resource "azurerm_subnet_nat_gateway_association" "container" {
  count = var.enable_nat_gateway_egress ? 1 : 0

  subnet_id      = azurerm_subnet.container.id
  nat_gateway_id = azurerm_nat_gateway.spoke[0].id
}

# Explicit allow rules (see local above), one per rule per delegated-subnet NSG.
resource "azurerm_network_security_rule" "nat_egress_allow" {
  for_each = local.nat_egress_rule_matrix

  name                        = "AllowOutbound-${each.value.key}"
  priority                    = each.value.rule.priority
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = each.value.rule.ports
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = each.value.rule.dest
  resource_group_name         = var.resource_group_name
  network_security_group_name = local.nat_nsg_names[each.value.nsg]
}

# Deny-Internet catch-all: overrides the default AllowInternetOutBound (65001)
# so anything not on the allowlist above (or Databricks' managed rules) drops.
resource "azurerm_network_security_rule" "nat_egress_deny_internet" {
  for_each = var.enable_nat_gateway_egress ? local.nat_nsg_names : {}

  name                        = "DenyAllInternetOutbound"
  priority                    = 4096
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "Internet"
  resource_group_name         = var.resource_group_name
  network_security_group_name = each.value
}
