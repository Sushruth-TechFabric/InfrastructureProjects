# =============================================================================
# modules/workspace-access — OUTPUTS
# =============================================================================

output "group_object_ids" {
  description = <<-EOT
    Logical key => Entra object id of each group. Feeds Azure-plane RBAC
    (the env root's resource_group_reader_groups grants) and any future consumer that
    grants to these groups. CAUTION: destroying a group invalidates this id for
    every such consumer — treat group deletion as a breaking change (ADR-0008).
  EOT
  value       = { for k, g in azuread_group.this : k => g.object_id }
}

output "group_display_names" {
  description = "Logical key => derived display name (grp-{project}-{env}-{role})."
  value       = { for k, g in azuread_group.this : k => g.display_name }
}

output "databricks_group_ids" {
  description = "Logical key => Databricks-internal group id (what UC grants and permission APIs bind to)."
  value       = { for k, g in databricks_group.this : k => g.id }
}
