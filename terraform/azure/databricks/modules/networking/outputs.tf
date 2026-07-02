# =============================================================================
# modules/networking — OUTPUTS
# -----------------------------------------------------------------------------
# Outputs are the module's public surface: the ids other resources need to
# attach to this network (the workspace's VNet injection, the private endpoints,
# the peering, the DNS zone links). Everything else stays internal.
# =============================================================================

output "vnet_id" {
  description = "Resource ID of the spoke VNet (used for peering and DNS zone links)."
  value       = azurerm_virtual_network.spoke.id
}

output "vnet_name" {
  description = "Name of the spoke VNet."
  value       = azurerm_virtual_network.spoke.name
}

output "host_subnet_id" {
  description = "Resource ID of the delegated host subnet (Databricks VNet injection)."
  value       = azurerm_subnet.host.id
}

output "host_subnet_name" {
  description = "Name of the delegated host subnet (Databricks needs the name, not just the id)."
  value       = azurerm_subnet.host.name
}

output "container_subnet_id" {
  description = "Resource ID of the delegated container subnet (Databricks VNet injection)."
  value       = azurerm_subnet.container.id
}

output "container_subnet_name" {
  description = "Name of the delegated container subnet."
  value       = azurerm_subnet.container.name
}

output "private_endpoint_subnet_id" {
  description = "Resource ID of the private-endpoint subnet (where ADLS/KV/Databricks PEs land)."
  value       = azurerm_subnet.private_endpoint.id
}

output "host_subnet_nsg_association_id" {
  description = "ID of the host subnet's NSG association (Databricks VNet injection needs this)."
  value       = azurerm_subnet_network_security_group_association.host.id
}

output "container_subnet_nsg_association_id" {
  description = "ID of the container subnet's NSG association (Databricks VNet injection needs this)."
  value       = azurerm_subnet_network_security_group_association.container.id
}
