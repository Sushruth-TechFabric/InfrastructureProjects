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
  description = "Azure Firewall name (spokes resolve its private IP by this name)."
  value       = azurerm_firewall.hub.name
}

output "firewall_private_ip" {
  description = "Firewall private IP — the forced-tunneling next hop for spoke route tables."
  value       = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "nat_public_ip" {
  description = "Stable outbound public IP (NAT gateway) — the auditable egress address."
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Names of the Private DNS zones created in the hub."
  value       = [for z in azurerm_private_dns_zone.this : z.name]
}
