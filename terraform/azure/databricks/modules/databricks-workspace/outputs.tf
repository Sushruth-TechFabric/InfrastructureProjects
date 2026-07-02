# =============================================================================
# modules/databricks-workspace — OUTPUTS
# =============================================================================

output "workspace_id" {
  description = "Azure resource ID of the workspace (target of the back-end Private Link private endpoint)."
  value       = azurerm_databricks_workspace.this.id
}

output "workspace_url" {
  description = "Workspace URL (host for the databricks provider + user access)."
  value       = azurerm_databricks_workspace.this.workspace_url
}

output "workspace_resource_id" {
  description = "Databricks internal workspace id (numeric) — needed by some databricks-provider resources later."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "managed_resource_group_id" {
  description = "Resource ID of the Databricks-managed resource group."
  value       = azurerm_databricks_workspace.this.managed_resource_group_id
}
