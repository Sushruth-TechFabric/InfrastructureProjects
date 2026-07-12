# =============================================================================
# environments/dev — SQL WAREHOUSE (BI / SQL capability, cost-conscious)
# -----------------------------------------------------------------------------
# CLASSIC (non-serverless) warehouse on purpose. This environment's ADLS has
# public network access DISABLED (PE-only). A classic warehouse runs in the
# workspace's own VNet-injected compute plane and reaches PE-only storage over
# the existing back-end Private Link + ADLS private endpoints — ZERO new infra.
# A SERVERLESS warehouse runs in a Databricks-managed plane; its private path to
# PE-only storage NOW EXISTS via the Network Connectivity Config in
# network-connectivity.tf (ADR-0012). enable_serverless_compute still stays
# false here on purpose: flipping it is a deliberate follow-up behavior/cost
# change (serverless billing model), separate from standing up the path. See
# ADR-0006 / ADR-0012 for the trade-off.
#
# Cost posture mirrors the cluster policies: smallest size, single cluster (no
# autoscaling headroom to pay for in dev), aggressive auto-stop so idle time
# does not bill. Sizing/grant knobs live in terraform.tfvars so promoting this
# root to staging/prod is a values change, not a code change.
#
# CAN_USE granted to GROUPS only (AGENTS.md rule 10); workspace admins keep
# implicit access and take no explicit entry.
# =============================================================================

variable "warehouse_cluster_size" {
  type        = string
  description = "SQL warehouse cluster size (Databricks t-shirt size, e.g. 2X-Small). Start smallest; size up from evidence, not assumption."
  default     = "2X-Small"
}

variable "warehouse_auto_stop_mins" {
  type        = number
  description = "Idle minutes before the SQL warehouse auto-stops. Dev optimizes for cheap-when-idle; a stopped warehouse costs $0."
  default     = 10

  validation {
    condition     = var.warehouse_auto_stop_mins >= 5
    error_message = "warehouse_auto_stop_mins must be >= 5 (the SQL warehouse minimum auto-stop)."
  }
}

variable "sql_warehouse_can_use" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted CAN_USE on the dev SQL warehouse (i.e. who may
    run queries against it). Grants go to GROUPS only. Empty list = admins only
    (admins have implicit access). AUTHORITATIVE: UI-added grants not listed
    here are reverted on the next apply.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.sql_warehouse_can_use : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every entry of sql_warehouse_can_use must be a key of identity_groups (use the logical key, e.g. \"bi_users\")."
  }
}

resource "databricks_sql_endpoint" "dev" {
  name             = "sql-${local.name_suffix}"
  cluster_size     = var.warehouse_cluster_size
  min_num_clusters = 1
  max_num_clusters = 1 # no multi-cluster autoscaling in dev
  auto_stop_mins   = var.warehouse_auto_stop_mins
  warehouse_type   = "PRO"

  enable_serverless_compute = false # classic — serverless path now exists (NCC, ADR-0012) but flipping this is a separate cost decision (see header)
  enable_photon             = true  # not an extra cost dimension on SQL warehouses; speeds up BI queries
  spot_instance_policy      = "COST_OPTIMIZED"
}

# CAN_USE is what makes the warehouse selectable by a non-admin BI/SQL user.
# count (not for_each): a single warehouse, and databricks_permissions rejects
# zero access_control blocks — so skip the resource entirely when nobody is
# granted (admins-only).
resource "databricks_permissions" "sql_warehouse" {
  count = length(var.sql_warehouse_can_use) > 0 ? 1 : 0

  sql_endpoint_id = databricks_sql_endpoint.dev.id

  dynamic "access_control" {
    for_each = toset(distinct(var.sql_warehouse_can_use))
    content {
      group_name       = module.workspace_access.group_display_names[access_control.value]
      permission_level = "CAN_USE"
    }
  }

  depends_on = [module.workspace_access]
}
