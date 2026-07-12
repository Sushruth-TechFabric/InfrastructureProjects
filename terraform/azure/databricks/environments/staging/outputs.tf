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

output "egress_public_ip" {
  description = "Stable outbound public IP of the spoke NAT Gateway (what external services see; add to allowlists that need the cluster egress address)."
  value       = module.networking.nat_gateway_public_ip
}

output "storage_account_name" {
  description = "ADLS Gen2 account name."
  value       = module.storage.storage_account_name
}

output "access_connector_identity_principal_id" {
  description = "Principal id of the UAMI granted Storage Blob Data Contributor (used by UC storage credential later)."
  value       = module.identity.user_assigned_identity_principal_id
}

output "identity_group_object_ids" {
  description = "Logical key => Entra object id of each workspace-access group (feeds resource_group_reader_groups RBAC / future UC grants; ADR-0008)."
  value       = module.workspace_access.group_object_ids
}

output "ncc_id" {
  description = "Network Connectivity Config id backing serverless private connectivity (ADR-0012)."
  value       = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
}

output "serverless_pe_connection_state" {
  description = "group_id (blob/dfs/vault) => connection state of each serverless private endpoint rule. Expect ESTABLISHED once the azapi approval has applied (two-phase; ADR-0012)."
  value       = { for k, r in databricks_mws_ncc_private_endpoint_rule.this : k => r.connection_state }
}

output "lakebase_instance_name" {
  description = "Lakebase managed Postgres instance name, or null when lakebase_enabled = false (ADR-0013)."
  value       = one(databricks_database_instance.dev[*].name)
}

output "lakebase_read_write_dns" {
  description = "Lakebase primary (read-write) hostname, or null when disabled. Not a secret — clients still authenticate with a Databricks OAuth token (no PG password)."
  value       = one(databricks_database_instance.dev[*].read_write_dns)
}

output "lakebase_state" {
  description = "Lakebase instance state (AVAILABLE / STOPPED / ...), or null when disabled. Reflects the lakebase_stopped cost lever."
  value       = one(databricks_database_instance.dev[*].state)
}
