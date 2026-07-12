# =============================================================================
# shared-services — OUTPUTS
# -----------------------------------------------------------------------------
# NOTE: environment roots do NOT read these outputs (that would be cross-state
# coupling via remote_state, which we forbid). They re-resolve hub resources by
# NAME using Azure data sources. These outputs exist for humans and for quick
# `terraform output` inspection / debugging.
# =============================================================================

output "hub_resource_group_name" {
  description = "Hub resource group name."
  value       = azurerm_resource_group.hub.name
}

output "hub_vnet_name" {
  description = "Hub VNet name (spokes peer to this by name)."
  value       = azurerm_virtual_network.hub.name
}

output "hub_vnet_id" {
  description = "Hub VNet resource ID."
  value       = azurerm_virtual_network.hub.id
}

output "firewall_name" {
  description = "Azure Firewall name (spokes resolve its private IP by this name). Null unless deploy_firewall = true (ADR-0007)."
  value       = one(azurerm_firewall.hub[*].name)
}

output "firewall_private_ip" {
  description = "Firewall private IP — the forced-tunneling next hop for spoke route tables. Null unless deploy_firewall = true (ADR-0007)."
  value       = one(azurerm_firewall.hub[*].ip_configuration[0].private_ip_address)
}

output "nat_public_ip" {
  description = "Stable outbound public IP of the hub NAT gateway (firewall egress). Null unless deploy_firewall = true; in NAT-egress mode each spoke has its own NAT public IP (see the spoke's egress_public_ip output)."
  value       = one(azurerm_public_ip.nat[*].ip_address)
}

output "private_dns_zone_names" {
  description = "Names of the Private DNS zones created in the hub."
  value       = [for z in azurerm_private_dns_zone.this : z.name]
}

output "metastore_name" {
  description = "UC metastore name (env roots re-resolve it by this name via data \"databricks_metastore\" — the cross-state contract, ADR-0011)."
  value       = databricks_metastore.this.name
}

output "metastore_id" {
  description = "UC metastore UUID (for humans / `terraform output` debugging only)."
  value       = databricks_metastore.this.id
}
