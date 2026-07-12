# =============================================================================
# environments/dev — WORKSPACE CONTROLS (databricks provider, pass 2 / ADR-0002)
# -----------------------------------------------------------------------------
# Closes the "known gaps" deferred by ADR-0002:
#   1. Cluster policies — users cannot create clusters outside these bounds.
#      In Azure, VNet injection + SCC are WORKSPACE-level properties, so every
#      cluster automatically lives in our injected VNet with no public IP; the
#      policies' job is to lock down everything else a user could weaken:
#      security mode, node sizes, autoscale bounds, runtime, auto-termination.
#   2. Key Vault-backed secret scope — notebooks read secrets via
#      dbutils.secrets.get(); values physically stay in Key Vault.
#
# The front-end is internet-reachable BY DESIGN, gated by Entra ID (plus
# Conditional Access at the tenant level). The workspace IP access list that
# used to narrow it to known egress IPs was removed by ADR-0010.
#
# ORDERING / REACHABILITY CAVEATS (read before first apply):
#   - These resources need the workspace to EXIST.
#     Fresh deploy: `terraform apply "-target=module.databricks_workspace"` (keep
#     the quotes — portable across shells), then full `terraform apply`.
#   - The KV-backed secret scope is created via an Entra user token (az login).
#     Historically it fails under pure service-principal auth; if CI needs it,
#     revisit with the latest provider docs. Also: our Key Vault is private-only
#     (PE + public access off), but scope creation only registers KV metadata
#     with Databricks — reads happen from the workspace side.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Cluster policies (personal / jobs / shared), per architecture doc §4
# ---------------------------------------------------------------------------
# Policy JSON uses the Databricks policy-definition schema:
#   fixed     -> user cannot change the value
#   range     -> user may pick within bounds
#   allowlist -> user may pick from the list
# WHO may use each policy is granted in workspace-permissions.tf, driven by
# var.cluster_policy_can_use (ADR-0009). With no grant, a policy is admins-only.
locals {
  # One place to change the approved node sizes for this environment.
  policy_node_types = var.policy_node_types

  policy_common = {
    # Auto-termination cannot be disabled (0 = never, so minValue 10 blocks it).
    "autotermination_minutes" : {
      "type" : "range",
      "minValue" : 10,
      "maxValue" : var.policy_max_autotermination_minutes,
      "defaultValue" : 30
    },
    "node_type_id" : {
      "type" : "allowlist",
      "values" : local.policy_node_types
    },
    "driver_node_type_id" : {
      "type" : "allowlist",
      "values" : local.policy_node_types
    },
    # Restrict to long-term-support runtimes. "regex" (not "unlimited") is what
    # actually enforces this — "unlimited" let users pick ANY runtime string
    # (T12, 2026-07 review); defaultValue "auto:latest-lts" still satisfies the
    # pattern (it contains "-lts"), so the default keeps working unchanged.
    "spark_version" : {
      "type" : "regex",
      "pattern" : ".*-lts.*",
      "defaultValue" : "auto:latest-lts"
    }
  }
}

# Personal compute: one user, small, UC-capable (SINGLE_USER).
resource "databricks_cluster_policy" "personal" {
  name = "${var.project}-${var.environment}-personal"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "all-purpose" },
    "data_security_mode" : { "type" : "fixed", "value" : "SINGLE_USER" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 1, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 },
    # T12: without this, a user can request a FIXED-size cluster (num_workers)
    # and bypass the autoscale.* bounds above entirely. maxValue mirrors
    # autoscale.max_workers' maxValue so a fixed-size cluster obeys the same cap.
    # isOptional=true: a "range" constraint is otherwise treated as a required
    # attribute, which would force every cluster-create request to also supply
    # num_workers alongside the (required) autoscale.* fields above — but
    # num_workers/autoscale are mutually exclusive in the Clusters API. Optional
    # keeps autoscale-only creation the unconstrained default path while still
    # bounding num_workers IF a caller supplies it instead.
    "num_workers" : { "type" : "range", "minValue" : 0, "maxValue" : 2, "isOptional" : true }
  }))
}

# Jobs compute: created by the scheduler, dies with the job.
resource "databricks_cluster_policy" "jobs" {
  name = "${var.project}-${var.environment}-jobs"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "job" },
    "data_security_mode" : { "type" : "fixed", "value" : "SINGLE_USER" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : var.policy_max_workers, "defaultValue" : 2 },
    # T12: caps fixed-size (non-autoscale) clusters to the same ceiling as
    # autoscale.max_workers above. isOptional=true: see the "personal" policy
    # above for why (num_workers/autoscale are mutually exclusive in the API).
    "num_workers" : { "type" : "range", "minValue" : 0, "maxValue" : var.policy_max_workers, "isOptional" : true }
  }))
}

# Shared compute: multiple users -> USER_ISOLATION so UC enforces per-user access.
resource "databricks_cluster_policy" "shared" {
  name = "${var.project}-${var.environment}-shared"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "all-purpose" },
    "data_security_mode" : { "type" : "fixed", "value" : "USER_ISOLATION" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : var.policy_max_workers, "defaultValue" : 2 },
    # T12: caps fixed-size (non-autoscale) clusters to the same ceiling as
    # autoscale.max_workers above. isOptional=true: see the "personal" policy
    # above for why (num_workers/autoscale are mutually exclusive in the API).
    "num_workers" : { "type" : "range", "minValue" : 0, "maxValue" : var.policy_max_workers, "isOptional" : true }
  }))
}

# ---------------------------------------------------------------------------
# 2. Key Vault-backed secret scope
# ---------------------------------------------------------------------------
# dbutils.secrets.get(scope = "kv-{project}-{env}", key = "<secret-name>") reads a
# secret that physically lives in our Key Vault — nothing is copied into
# Databricks. Access to the scope is governed by workspace ACLs: READ is granted
# per group by databricks_secret_acl.key_vault_read in workspace-permissions.tf,
# driven by var.secret_scope_read_groups (ADR-0009).
resource "databricks_secret_scope" "key_vault" {
  name = "kv-${var.project}-${var.environment}"

  keyvault_metadata {
    resource_id = module.key_vault.key_vault_id
    dns_name    = module.key_vault.key_vault_uri
  }
}
