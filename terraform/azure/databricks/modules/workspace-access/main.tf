# =============================================================================
# modules/workspace-access — ENTRA GROUPS -> DATABRICKS WORKSPACE (ADR-0008)
# -----------------------------------------------------------------------------
# Who can open the workspace, and as what (ADMIN vs USER), as declarative
# config. Three links per group:
#
#   azuread_group                        Entra ID — THE source of truth.
#        |                               Membership is authoritative and
#        v                               PR-driven.
#   databricks_group                     A thin "materialization shell" in the
#        |                               Databricks ACCOUNT. Required because
#        v                               the assignment API cannot reference a
#   databricks_mws_permission_assignment group that exists only in Entra
#                                        (provider issue #5414), and the AIM
#                                        resolveByExternalId API has no
#                                        Terraform support yet.
#
# MEMBERSHIP IS NOT MANAGED HERE. Automatic Identity Management (AIM) syncs
# members from Entra into Databricks at auth time (<=5 min on browser login,
# <=40 min on token/job auth) — so there is deliberately NO
# databricks_group_member in this module, and AIM-managed groups are read-only
# in the account console (membership drift on the Databricks side is
# structurally impossible). AIM enabled on the account is a hard prerequisite.
#
# The external_id = Entra objectId line is what ties the shell to AIM: it is
# AIM's authoritative identity link, and setting it at create time is what
# prevents AIM from ever minting a duplicate principal.
#
# Keep groups FLAT. AIM grants access through nested groups but never
# provisions them — a nested child is invisible to Terraform and the API, and
# can't receive UC grants or workspace-object permissions.
#
# PREREQUISITE (caller's responsibility): databricks_mws_permission_assignment
# below requires the target workspace to already be identity-federated
# (UC-attached to a metastore). This module has no knowledge of the metastore
# assignment — the calling root MUST add
# depends_on = [databricks_metastore_assignment.this] (or equivalent) on this
# module block, or apply can race and fail with "workspace not enabled for
# identity federation" on any account that doesn't auto-attach a default
# metastore. See environments/dev/main.tf's module "workspace_access" block.
# =============================================================================

locals {
  # Every distinct UPN across all groups, resolved against Entra exactly once.
  all_member_upns = distinct(flatten([for g in var.groups : g.members]))
}

# Deployer context: the applying identity is always a group owner, which is
# also what lets a least-privilege CI principal (Group.Create, no tenant-wide
# Group.ReadWrite.All) manage these groups later. var.group_owners adds the
# other side (human or CI) so ownership doesn't churn between apply identities.
data "azuread_client_config" "current" {}

# A UPN that isn't in the tenant fails the PLAN — deliberately loud. User
# lifecycle (joiners/leavers) is Entra's concern, not this module's.
data "azuread_user" "members" {
  for_each            = toset(local.all_member_upns)
  user_principal_name = each.key
}

resource "azuread_group" "this" {
  for_each = var.groups

  display_name     = "grp-${var.project}-${var.environment}-${each.value.role_token}"
  security_enabled = true

  # Entra display names are NOT unique. Without this, a cold apply against a
  # pre-existing same-name group would silently create a second group with a
  # different object id; with it, the apply fails and forces the operator down
  # the `terraform import` path.
  prevent_duplicate_names = true

  # distinct(): the deployer is always included so a lone human/CI apply never
  # locks itself out of ownership; var.group_owners layers in the other side
  # (typically the CI OIDC SP's object id) so ownership is stable across both
  # human az login and CI applies instead of churning to whichever applied last.
  owners = distinct(concat([data.azuread_client_config.current.object_id], var.group_owners))

  # AUTHORITATIVE membership: the config list is the whole list. Members added
  # by hand in the Entra portal are removed on the next apply — a PR to this
  # config is the only way in. (Never mix azuread_group_member resources with
  # this — the two fight and members get dropped.)
  members = [
    for upn in each.value.members : data.azuread_user.members[upn].object_id
  ]
}

# The materialization shell. A direct SCIM create from values Terraform already
# knows — it does not wait on or query AIM, so there is no sync race here.
resource "databricks_group" "this" {
  provider = databricks.account
  for_each = var.groups

  display_name = azuread_group.this[each.key].display_name
  external_id  = azuread_group.this[each.key].object_id

  # If AIM or a console admin already materialized the group, adopt it instead
  # of erroring — the external_id link makes it the same principal either way.
  force = true
}

# Workspace binding: ADMIN -> workspace admins group, USER -> workspace users.
# principal_id is the Databricks-INTERNAL group id (never the Entra object id)
# and is force-new — another reason the shell above must never be casually
# recreated. Known flake: creation can intermittently report "Principal not in
# workspace" (provider issue #5367, eventual consistency); a re-apply converges.
resource "databricks_mws_permission_assignment" "this" {
  provider = databricks.account
  for_each = var.groups

  workspace_id = var.workspace_id
  principal_id = databricks_group.this[each.key].id
  permissions  = [each.value.workspace_permission]
}
