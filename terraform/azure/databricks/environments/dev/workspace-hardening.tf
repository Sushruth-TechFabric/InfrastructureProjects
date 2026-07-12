# =============================================================================
# environments/dev — WORKSPACE HARDENING (T11 / I6, 2026-07 platform review)
# -----------------------------------------------------------------------------
# THREAT MODEL (ADR-0010): the workspace front-end is internet-reachable BY
# DESIGN — no front-end Private Link, no workspace IP access list. Identity
# (Entra ID + Conditional Access) is the ONLY perimeter. ADR-0010's own
# "Consequences" section names the trade-off explicitly: "a stolen-but-valid
# credential can now be used from any IP." Against that threat model, a
# Personal Access Token with an unbounded lifetime is a standing exposure —
# every setting below is a compensating control for an internet-reachable
# control plane, not generic hygiene. None of these are tfvars knobs: they are
# golden-rule invariants (references/databricks.md §8, "workspace hardening
# (least functionality)"), hardcoded on purpose so they can't be silently
# loosened by an environment's tfvars.
#
# Resources here use the WORKSPACE-scoped `databricks` provider (default,
# unaliased) — the same provider workspace-config.tf's cluster policies and
# secret scope use. Entitlements and workspace conf are workspace-level
# concepts; they have no meaning against the account-level provider alias
# (`databricks.account`) that modules/workspace-access uses to create the
# group shells.
#
# NEEDS MANUAL RUNTIME VERIFICATION (flagged, not guessed — 2026-07 review):
#   1. enforceUserIsolation vs. the SINGLE_USER personal-compute cluster
#      policy (workspace-config.tf's "personal" and "jobs" policies pin
#      data_security_mode to SINGLE_USER). Microsoft's docs describe the
#      setting as blocking only the "No Isolation Shared" access mode (and its
#      legacy equivalent), with no documented interaction with SINGLE_USER —
#      but that reading is secondhand, not verified against this workspace.
#      Confirm in a real workspace that turning it on does not affect or
#      reject SINGLE_USER/USER_ISOLATION cluster creation before relying on it.
#   2. Whether the workspace built-in `users` group currently carries
#      cluster-create / instance-pool-create entitlements at all (only
#      visible in the admin console or via API read, not from this repo) —
#      i.e. confirm this file is closing a real gap and not a no-op.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Workspace conf (T11) — token lifetime + notebook exfil controls
# ---------------------------------------------------------------------------
# maxTokenLifetimeDays: bounds how long a minted PAT stays valid — the direct
# mitigation for ADR-0010's "stolen credential usable from any IP" risk.
# enableExportNotebook / enableResultsDownloading: close the two built-in
# notebook exfil channels (workspace UI export, query-result download) — this
# environment already runs coarse NSG-based egress (ADR-0007), not a
# monitored/deny-by-default one, so an unmonitored in-product export path is
# the higher-value channel to close.
# enforceUserIsolation: forces UC's per-user isolation posture at the
# workspace level (defense in depth on top of the "shared" cluster policy's
# USER_ISOLATION data_security_mode) — see runtime-verification item 1 above
# for its interaction with the SINGLE_USER policies.
resource "databricks_workspace_conf" "hardening" {
  custom_config = {
    "maxTokenLifetimeDays"     = "90"
    "enableExportNotebook"     = "false"
    "enableResultsDownloading" = "false"
    "enforceUserIsolation"     = "true"
  }
}

# ---------------------------------------------------------------------------
# 2. Entitlements (I6) — strip risky entitlements from non-admin groups
# ---------------------------------------------------------------------------
# databricks_entitlements is AUTHORITATIVE for the entitlements it manages: an
# admin flipping "Allow cluster creation" back on for a group in the console
# is reverted on the next apply, closing the exact drift path I6 flags
# ("invisible to plan forever").

# 2a. The workspace BUILT-IN `users` group (every workspace member, distinct
# from our custom grp-{project}-{env}-users group below). Unrestricted
# cluster/instance-pool creation here would let ANY workspace member bypass
# every cluster policy in workspace-config.tf outright (compounds T12) —
# see runtime-verification item 2 above for whether this closes a real gap.
# Only these two entitlements are managed here; workspace_access and
# databricks_sql_access are deliberately left unmanaged for the built-in
# group (it implicitly contains every member, including admins — scoping
# those two here risks locking out the workspace rather than hardening it).
data "databricks_group" "users" {
  display_name = "users"
}

resource "databricks_entitlements" "workspace_users" {
  group_id = data.databricks_group.users.id

  allow_cluster_create       = false
  allow_instance_pool_create = false
}

# 2b. Our managed non-admin groups (modules/workspace-access, ADR-0008).
# `databricks_group_ids` (module output) is the group's id at the ACCOUNT
# scope — databricks_group.this in the module is explicitly created with
# `provider = databricks.account`. databricks_entitlements is a WORKSPACE-
# scoped resource (it has no meaning against the account API), and the
# provider's own documented pattern for this exact hand-off (account-level
# group -> workspace-scoped resource) is a SEPARATE workspace-scoped
# `data "databricks_group"` lookup by display name after the permission
# assignment lands — not reuse of the account-level id. Mirrors the built-in
# `users` group lookup above; do not assume the two ids coincide.
data "databricks_group" "non_admin" {
  for_each = {
    for logical_key, display_name in module.workspace_access.group_display_names :
    logical_key => display_name
    if logical_key != "admins"
  }

  display_name = each.value

  # module.workspace_access.databricks_mws_permission_assignment must have
  # landed before this group is visible to the WORKSPACE-scoped provider.
  depends_on = [module.workspace_access]
}

# All non-admin groups: no unrestricted cluster/instance-pool creation —
# compute access is granted exclusively through cluster-policy CAN_USE grants
# (workspace-permissions.tf, driven by var.cluster_policy_can_use), which
# still works without this entitlement (policy-scoped creation doesn't need
# it). workspace_access = true so every granted group can actually sign in
# and use whatever it's been granted. databricks_sql_access mirrors the
# existing SQL warehouse grant (sql-warehouse.tf's var.sql_warehouse_can_use)
# so a group isn't locked out of a surface it's already been granted, and
# isn't granted a surface (the DBSQL persona) it has no other access to.
#
# "admins" is excluded — workspace admins keep full implicit entitlements,
# consistent with workspace-permissions.tf's existing "admins get no explicit
# grant" convention.
resource "databricks_entitlements" "non_admin_groups" {
  for_each = data.databricks_group.non_admin

  group_id = each.value.id

  workspace_access           = true
  allow_cluster_create       = false
  allow_instance_pool_create = false
  databricks_sql_access      = contains(var.sql_warehouse_can_use, each.key)
}
