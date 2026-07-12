# =============================================================================
# environments/dev-lab — WORKSPACE CONTROLS (databricks provider)
# -----------------------------------------------------------------------------
# Everything here needs the workspace to EXIST —
# see the two-phase apply note in providers.tf / README.md.
#
# The front-end is internet-reachable, gated by Entra ID. The workspace IP
# access list that used to narrow it further was removed by ADR-0010.
# (`allowed_ip_addresses` still gates the storage/Key Vault firewalls — main.tf.)
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Cluster policy — the guardrail that makes runaway compute IMPOSSIBLE
# ---------------------------------------------------------------------------
# Everything cost-dangerous is `fixed` (user cannot change it in the UI):
#   - single node (num_workers 0), small VM allowlist, no Photon (2x DBU)
#   - auto-termination FIXED — cannot be raised, cannot be disabled
#   - SINGLE_USER security mode so the cluster is Unity-Catalog-capable
resource "databricks_cluster_policy" "lab_personal" {
  name = "lab-personal"

  definition = jsonencode({
    "spark_conf.spark.databricks.cluster.profile" : {
      "type" : "fixed", "value" : "singleNode"
    },
    "spark_conf.spark.master" : {
      "type" : "fixed", "value" : "local[*]"
    },
    "custom_tags.ResourceClass" : {
      "type" : "fixed", "value" : "SingleNode"
    },
    "num_workers" : { "type" : "fixed", "value" : 0 },
    "node_type_id" : {
      "type" : "allowlist", "values" : [var.cluster_node_type]
    },
    "autotermination_minutes" : {
      "type" : "fixed", "value" : var.autotermination_minutes
    },
    "runtime_engine" : { "type" : "fixed", "value" : "STANDARD" }, # no Photon: 2x DBU
    "data_security_mode" : { "type" : "fixed", "value" : "SINGLE_USER" },
    "cluster_type" : { "type" : "fixed", "value" : "all-purpose" },
    "spark_version" : {
      "type" : "unlimited", "defaultValue" : "auto:latest-lts"
    }
  })
}

# ---------------------------------------------------------------------------
# 2. The practice cluster (single node, under the policy)
# ---------------------------------------------------------------------------
# A TERMINATED cluster costs $0 — its definition just sits in the workspace,
# pinned so the UI never garbage-collects it. NOTE: creating it starts it once
# (a few cents); it auto-terminates after `autotermination_minutes`.
data "databricks_spark_version" "lts" {
  long_term_support = true
}

data "databricks_current_user" "me" {}

resource "databricks_cluster" "practice" {
  cluster_name = "lab-practice"
  policy_id    = databricks_cluster_policy.lab_personal.id

  spark_version           = data.databricks_spark_version.lts.id
  node_type_id            = var.cluster_node_type
  num_workers             = 0
  autotermination_minutes = var.autotermination_minutes
  runtime_engine          = "STANDARD"

  data_security_mode = "SINGLE_USER"
  single_user_name   = data.databricks_current_user.me.user_name

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  custom_tags = {
    "ResourceClass" = "SingleNode"
  }

  is_pinned = true
}

# ---------------------------------------------------------------------------
# 3. SQL warehouse — serverless 2X-Small, aggressive auto-stop
# ---------------------------------------------------------------------------
# Serverless: zero idle cost, ~seconds to start. If your account/region lacks
# serverless, set enable_serverless = false to fall back to a classic PRO
# warehouse with the same size + auto-stop (slower start, same $0 when stopped).
resource "databricks_sql_endpoint" "lab" {
  name             = "lab-sql"
  cluster_size     = "2X-Small"
  auto_stop_mins   = var.warehouse_auto_stop_mins
  max_num_clusters = 1
  warehouse_type   = "PRO"

  enable_serverless_compute = var.enable_serverless
}

# ---------------------------------------------------------------------------
# 4. Databricks-backed secret scope for practice secrets
# ---------------------------------------------------------------------------
# For real platform secrets the pattern is a KEY-VAULT-BACKED scope (see the
# secure root). This lab keeps a plain Databricks-backed scope for throwaway
# practice values; the Key Vault is still deployed for practicing KV itself.
resource "databricks_secret_scope" "lab" {
  name = "lab"
}
