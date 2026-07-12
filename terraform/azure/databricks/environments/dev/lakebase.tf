# =============================================================================
# environments/dev — LAKEBASE (managed Postgres / OLTP) — ADR-0013
# -----------------------------------------------------------------------------
# Lakebase is Databricks' serverless managed Postgres. It runs in the
# Databricks-MANAGED serverless plane (the plane ADR-0012's NCC gave a private
# path to our data), and is identity-native: connections authenticate with a
# Databricks OAuth token, NOT a Postgres password.
#
# SECRETLESS (golden rule): enable_pg_native_login = false turns OFF Postgres
# username/password auth entirely — the only way in is a Databricks identity.
# The resource stores no password; read_write_dns is just a hostname. Nothing
# sensitive lands in tracked files or state.
#
# COST (dev economics): smallest capacity (CU_1), the minimum backup retention
# (2 days), a single node (no read replicas), and a `stopped` lever to pause the
# instance (storage-only billing) when idle. NOTE: the database-instance surface
# has no per-minute auto-suspend timeout (that knob lives only on the lower-level
# postgres_endpoint surface) — so "cheap when idle" here means stop-when-idle,
# not auto-suspend. See ADR-0013 for the trade-off and the scale-to-zero
# follow-up.
#
# ENABLEMENT: Lakebase must be enabled for the workspace/account (a one-time
# console step — serverless on in-region). No Terraform resource toggles it; a
# disabled feature fails create with "feature not enabled." See the deploy-dev
# runbook "Lakebase" step.
#
# ACCESS: granted to GROUPS only via databricks_permissions (ADR-0009 seam, the
# same pattern as sql-warehouse.tf). Workspace admins keep implicit access and
# take no explicit entry.
#
# OPT-IN: not every environment needs OLTP, so the whole feature is gated behind
# lakebase_enabled (default false). Set it true in an env's terraform.tfvars to
# provision the instance; left false, this file creates nothing. This keeps the
# toggle Terraform-driven — a tfvars change, not a code change, per environment.
# =============================================================================

variable "lakebase_enabled" {
  type        = bool
  description = "Provision Lakebase (managed Postgres) in this environment. Default off — OLTP is opt-in per deployment. Requires the console enablement prerequisite (ADR-0013 / runbook)."
  default     = false
}

variable "lakebase_capacity" {
  type        = string
  description = "Lakebase compute capacity (CU_1/CU_2/CU_4/CU_8). Start smallest; size up from evidence, not assumption."
  default     = "CU_1"

  validation {
    condition     = contains(["CU_1", "CU_2", "CU_4", "CU_8"], var.lakebase_capacity)
    error_message = "lakebase_capacity must be one of CU_1, CU_2, CU_4, CU_8."
  }
}

variable "lakebase_retention_days" {
  type        = number
  description = "Point-in-time restore window in days. Dev uses the minimum (2) to keep backup cost down."
  default     = 2

  validation {
    condition     = var.lakebase_retention_days >= 2 && var.lakebase_retention_days <= 35
    error_message = "lakebase_retention_days must be between 2 and 35."
  }
}

variable "lakebase_stopped" {
  type        = bool
  description = "Cost lever: set true to pause the instance (storage-only billing). A stopped instance runs no compute."
  default     = false
}

variable "lakebase_can_manage" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted CAN_MANAGE on the Lakebase instance (admin:
    settings, roles, delete). Grants go to GROUPS only. Empty list = admins only.
    AUTHORITATIVE: UI-added grants not listed here are reverted on the next apply.
    Default [] so this validates cleanly even when lakebase_enabled = false and
    a client's identity_groups doesn't define an "engineers" key; dev sets its
    real list explicitly in terraform.tfvars.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.lakebase_can_manage : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every lakebase_can_manage entry must be a key of identity_groups (use the logical key, e.g. \"engineers\")."
  }
}

variable "lakebase_can_use" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted CAN_USE on the Lakebase instance (connect and
    run SQL). Grants go to GROUPS only. Empty list = admins only. AUTHORITATIVE.
    Default [] so this validates cleanly even when lakebase_enabled = false and
    a client's identity_groups doesn't define "users"/"bi_users" keys; dev sets
    its real list explicitly in terraform.tfvars.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.lakebase_can_use : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every lakebase_can_use entry must be a key of identity_groups (use the logical key, e.g. \"bi_users\")."
  }

  # A principal may hold only one permission level; overlap would emit duplicate
  # access_control blocks for the same group. (Terraform >= 1.9 allows a
  # validation to reference another variable.)
  validation {
    condition     = length(setintersection(toset(var.lakebase_can_use), toset(var.lakebase_can_manage))) == 0
    error_message = "A group cannot be in both lakebase_can_use and lakebase_can_manage (duplicate principal)."
  }
}

variable "lakebase_purge_on_delete" {
  type        = bool
  description = <<-EOT
    Purge the Lakebase instance's underlying storage on delete (clean teardown,
    no lingering storage/cost). Default false (safer — leaves storage recoverable);
    dev's tfvars sets this true to preserve its existing clean-teardown behavior.
  EOT
  default     = false
}

# Lakebase managed Postgres instance. count gates the whole feature on the
# lakebase_enabled toggle (opt-in per environment). custom_tags is a list of
# {key,value} objects (not a map), so project the common tag map into that shape.
resource "databricks_database_instance" "dev" {
  count = var.lakebase_enabled ? 1 : 0

  name                        = "lb-${local.name_suffix}" # lb-dbx-dev-wus3-001
  capacity                    = var.lakebase_capacity
  node_count                  = 1 # single node — no read replicas in dev
  enable_readable_secondaries = false
  enable_pg_native_login      = false # SECRETLESS: OAuth/Databricks identity only, no PG passwords
  retention_window_in_days    = var.lakebase_retention_days
  stopped                     = var.lakebase_stopped
  purge_on_delete             = var.lakebase_purge_on_delete

  custom_tags = [for k, v in local.common_tags : { key = k, value = v }]
}

# CAN_USE / CAN_MANAGE granted to GROUPS only (ADR-0009). count (not for_each):
# databricks_permissions rejects zero access_control blocks — so skip the
# resource entirely when the feature is off or nobody is granted (admins-only).
resource "databricks_permissions" "lakebase" {
  count = var.lakebase_enabled && length(var.lakebase_can_use) + length(var.lakebase_can_manage) > 0 ? 1 : 0

  database_instance_name = databricks_database_instance.dev[0].name

  dynamic "access_control" {
    for_each = toset(distinct(var.lakebase_can_manage))
    content {
      group_name       = module.workspace_access.group_display_names[access_control.value]
      permission_level = "CAN_MANAGE"
    }
  }

  dynamic "access_control" {
    for_each = toset(distinct(var.lakebase_can_use))
    content {
      group_name       = module.workspace_access.group_display_names[access_control.value]
      permission_level = "CAN_USE"
    }
  }

  depends_on = [module.workspace_access]
}
