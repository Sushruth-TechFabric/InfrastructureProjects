# =============================================================================
# environments/dev — OUTPUTS (handy values after apply)
# =============================================================================

output "workspace_url" {
  description = "Databricks workspace URL (front-end, identity-gated)."
  value       = module.databricks_workspace.workspace_url
}

output "workspace_id" {
  description = "Azure resource ID of the Databricks workspace."
  value       = module.databricks_workspace.workspace_id
}

output "spoke_vnet_id" {
  description = "Dev spoke VNet resource ID."
  value       = module.networking.vnet_id
}

output "storage_account_name" {
  description = "ADLS Gen2 account name."
  value       = module.storage.storage_account_name
}

output "access_connector_identity_principal_id" {
  description = "Principal id of the UAMI granted Storage Blob Data Contributor (used by UC storage credential later)."
  value       = module.identity.user_assigned_identity_principal_id
}
