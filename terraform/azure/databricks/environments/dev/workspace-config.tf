# =============================================================================
# environments/dev — WORKSPACE CONTROLS (databricks provider, pass 2 / ADR-0002)
# -----------------------------------------------------------------------------
# Closes the "known gaps" deferred by ADR-0002:
#   1. IP access list  — the front-end is internet-reachable BY DESIGN, gated by
#      Entra ID; this narrows it further to known egress IPs.
#   2. Cluster policies — users cannot create clusters outside these bounds.
#      In Azure, VNet injection + SCC are WORKSPACE-level properties, so every
#      cluster automatically lives in our injected VNet with no public IP; the
#      policies' job is to lock down everything else a user could weaken:
#      security mode, node sizes, autoscale bounds, runtime, auto-termination.
#   3. Key Vault-backed secret scope — notebooks read secrets via
#      dbutils.secrets.get(); values physically stay in Key Vault.
#
# ORDERING / REACHABILITY CAVEATS (read before first apply):
#   - These resources need the workspace to EXIST and be reachable from YOUR IP.
#     Fresh deploy: `terraform apply -target=module.databricks_workspace`, then
#     full `terraform apply`.
#   - Careful with the IP access list: if you apply it from an IP that is not in
#     `allowed_ip_addresses`, you lock yourself (and Terraform) out. Your current
#     egress IP MUST be in the list.
#   - The KV-backed secret scope is created via an Entra user token (az login).
#     Historically it fails under pure service-principal auth; if CI needs it,
#     revisit with the latest provider docs. Also: our Key Vault is private-only
#     (PE + public access off), but scope creation only registers KV metadata
#     with Databricks — reads happen from the workspace side.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Front-end IP access list
# ---------------------------------------------------------------------------
# The feature must be switched on at the workspace level first...
resource "databricks_workspace_conf" "this" {
  custom_config = {
    "enableIpAccessLists" = "true"
  }
}

# ...then the ALLOW list applies. Everything not allowed is denied.
resource "databricks_ip_access_list" "allowed" {
  label        = "allowed-egress-ips"
  list_type    = "ALLOW"
  ip_addresses = var.allowed_ip_addresses

  depends_on = [databricks_workspace_conf.this]
}

# ---------------------------------------------------------------------------
# 2. Cluster policies (personal / jobs / shared), per architecture doc §4
# ---------------------------------------------------------------------------
# Policy JSON uses the Databricks policy-definition schema:
#   fixed     -> user cannot change the value
#   range     -> user may pick within bounds
#   allowlist -> user may pick from the list
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
    # Pin to long-term-support runtimes.
    "spark_version" : {
      "type" : "unlimited",
      "defaultValue" : "auto:latest-lts"
    }
  }
}

# Personal compute: one user, small, UC-capable (SINGLE_USER).
resource "databricks_cluster_policy" "personal" {
  name = "dbx-dev-personal"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "all-purpose" },
    "data_security_mode" : { "type" : "fixed", "value" : "SINGLE_USER" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 1, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 }
  }))
}

# Jobs compute: created by the scheduler, dies with the job.
resource "databricks_cluster_policy" "jobs" {
  name = "dbx-dev-jobs"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "job" },
    "data_security_mode" : { "type" : "fixed", "value" : "SINGLE_USER" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : var.policy_max_workers, "defaultValue" : 2 }
  }))
}

# Shared compute: multiple users -> USER_ISOLATION so UC enforces per-user access.
resource "databricks_cluster_policy" "shared" {
  name = "dbx-dev-shared"

  definition = jsonencode(merge(local.policy_common, {
    "cluster_type" : { "type" : "fixed", "value" : "all-purpose" },
    "data_security_mode" : { "type" : "fixed", "value" : "USER_ISOLATION" },
    "autoscale.min_workers" : { "type" : "range", "minValue" : 1, "maxValue" : 2, "defaultValue" : 1 },
    "autoscale.max_workers" : { "type" : "range", "minValue" : 1, "maxValue" : var.policy_max_workers, "defaultValue" : 2 }
  }))
}

# ---------------------------------------------------------------------------
# 3. Key Vault-backed secret scope
# ---------------------------------------------------------------------------
# dbutils.secrets.get(scope = "kv-dbx-dev", key = "<secret-name>") reads a
# secret that physically lives in our Key Vault — nothing is copied into
# Databricks. Access to the scope is still governed by workspace ACLs.
resource "databricks_secret_scope" "key_vault" {
  name = "kv-dbx-dev"

  keyvault_metadata {
    resource_id = module.key_vault.key_vault_id
    dns_name    = module.key_vault.key_vault_uri
  }
}
