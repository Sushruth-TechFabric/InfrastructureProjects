# =============================================================================
# environments/dev-lab — OUTPUTS (handy values after apply)
# =============================================================================

output "workspace_url" {
  description = "Databricks workspace URL — bookmark this; it is your daily entry point."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace."
  value       = azurerm_databricks_workspace.this.id
}

output "sql_warehouse_id" {
  description = "Serverless SQL warehouse id (attach the SQL editor to it)."
  value       = databricks_sql_endpoint.lab.id
}

output "practice_cluster_id" {
  description = "Single-node practice cluster id (terminated = $0)."
  value       = databricks_cluster.practice.id
}

output "storage_account_name" {
  description = "ADLS Gen2 account backing the lab (bronze/silver/gold/catalog)."
  value       = module.storage.storage_account_name
}

output "catalog_name" {
  description = "Unity Catalog catalog for all practice work."
  value       = databricks_catalog.lab.name
}

output "key_vault_name" {
  description = "Lab Key Vault (for practicing KV-backed patterns)."
  value       = module.key_vault.key_vault_name
}
