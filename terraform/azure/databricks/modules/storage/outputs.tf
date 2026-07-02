# =============================================================================
# modules/storage — OUTPUTS
# =============================================================================

output "storage_account_id" {
  description = "Resource ID of the ADLS Gen2 account (RBAC scope + private endpoint target)."
  value       = azurerm_storage_account.adls.id
}

output "storage_account_name" {
  description = "Name of the ADLS Gen2 account."
  value       = azurerm_storage_account.adls.name
}

output "dfs_endpoint" {
  description = "Primary DFS (Data Lake) endpoint — used when defining UC external locations later."
  value       = azurerm_storage_account.adls.primary_dfs_endpoint
}

output "filesystem_ids" {
  description = "Map of filesystem name => resource id for the ADLS Gen2 filesystems (containers, managed via ARM)."
  value       = { for name, fs in azurerm_storage_container.this : name => fs.id }
}
