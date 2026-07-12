# =============================================================================
# environments/dev — WORKSPACE-OBJECT PERMISSIONS (who may USE what, ADR-0009)
# -----------------------------------------------------------------------------
# Wires the workspace objects defined in workspace-config.tf to the identity
# groups from modules/workspace-access (ADR-0008). Root-owned per ADR-0003:
# grants are cross-module glue, like the Storage Blob Data Contributor grant
# in main.tf. Grants go to GROUPS only (AGENTS.md rule 10); the group->grant
# matrix lives in terraform.tfvars so this file ports to staging/prod unchanged.
#
# Provider semantics that shape this file:
#   - databricks_permissions is AUTHORITATIVE per object: the access_control
#     blocks here are the ONLY non-admin grants on that object after apply
#     (UI-added grants are reverted — drift converges). It also may not be
#     created with zero access_control blocks, hence the empty-list filter.
#   - databricks_secret_acl is one ACL entry per (scope, principal); all its
#     arguments are force-new. It is NOT authoritative for the whole scope —
#     an ACL added out-of-band via the CLI is invisible to plan.
#   - Workspace admins implicitly manage cluster policies and secret scopes;
#     they get no explicit entry (least privilege, no redundant grants).
# =============================================================================

locals {
  # Logical policy key -> the hand-written policy resource in workspace-config.tf.
  # A fourth policy = one resource there + one line here + one entry in the
  # cluster_policy_can_use key validation.
  cluster_policy_ids = {
    personal = databricks_cluster_policy.personal.id
    jobs     = databricks_cluster_policy.jobs.id
    shared   = databricks_cluster_policy.shared.id
  }

  # Drop empty entries: databricks_permissions rejects zero access_control
  # blocks, and "no entry" is how tfvars expresses "admins only". distinct()
  # tolerates an accidental duplicate in tfvars.
  cluster_policy_grants = {
    for policy_key, group_keys in var.cluster_policy_can_use :
    policy_key => distinct(group_keys)
    if length(group_keys) > 0
  }
}

# CAN_USE is the only grantable permission on a cluster policy; holding it is
# what makes the policy appear in a non-admin user's cluster-create UI.
resource "databricks_permissions" "cluster_policy" {
  for_each = local.cluster_policy_grants

  cluster_policy_id = local.cluster_policy_ids[each.key]

  dynamic "access_control" {
    for_each = toset(each.value)
    content {
      group_name       = module.workspace_access.group_display_names[access_control.value]
      permission_level = "CAN_USE"
    }
  }

  # group_display_names is derived from azuread_group alone, so without this
  # the grant could race the databricks_group shell / workspace assignment and
  # fail with "Group ... does not exist". Waits for the module's full chain.
  depends_on = [module.workspace_access]
}

# One ACL entry per granted group, keyed by the IMMUTABLE logical group key
# (never the display name) so a role_token rename replaces the ACL content
# without churning the resource address.
resource "databricks_secret_acl" "key_vault_read" {
  for_each = toset(var.secret_scope_read_groups)

  scope      = databricks_secret_scope.key_vault.name
  principal  = module.workspace_access.group_display_names[each.key]
  permission = "READ"

  depends_on = [module.workspace_access]
}
