# =============================================================================
# modules/identity — OUTPUTS
# =============================================================================

output "access_connector_id" {
  description = "Resource ID of the Databricks Access Connector (referenced by UC storage credential later)."
  value       = azurerm_databricks_access_connector.this.id
}

output "user_assigned_identity_id" {
  description = "Resource ID of the user-assigned managed identity."
  value       = azurerm_user_assigned_identity.connector.id
}

output "user_assigned_identity_principal_id" {
  description = "Principal (object) ID of the UAMI — the assignee for the Storage Blob Data Contributor grant in the root."
  value       = azurerm_user_assigned_identity.connector.principal_id
}
