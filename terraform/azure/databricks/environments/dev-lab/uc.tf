# =============================================================================
# environments/dev-lab — UNITY CATALOG (workspace-level chain only)
# -----------------------------------------------------------------------------
# NO `databricks_metastore` HERE — on purpose. New Databricks accounts are
# auto-enabled for Unity Catalog: a regional default metastore auto-attaches to
# new workspaces. Managing one in Terraform would drag in the ACCOUNT-level
# provider auth path for zero benefit in a solo lab. (Since ADR-0011 that same
# regional metastore IS Terraform-managed — in shared-services, named
# mst-dbx-shared-wus3-001. Nothing changes here: auto-attach still applies.)
#
# PREFLIGHT (after phase-1 apply, before the full apply): open the workspace →
# Catalog. If you see `main`/catalog browsing, the metastore is attached —
# proceed. If not (older account), attach one once via
# accounts.azuredatabricks.net (account admin) and re-run apply. README.md §7.
#
# The chain built here: storage credential (wraps the Access Connector UAMI)
#   → external locations (bronze/silver/gold + catalog managed storage)
#   → catalog `lab` → schemas `raw`, `curated` → grants.
#
# GRANTS EXCEPTION, documented: grants go to the DEPLOYING USER, not a group —
# a solo-lab exception to the platform's groups-only rule (ADR-0006), because
# no Entra→account group sync exists yet. Revert when identity federation lands.
#
# `force_destroy` is set on every UC object: this lab is built to deploy and
# destroy freely, and practice tables must never wedge `terraform destroy`.
# (The secure environments would NOT do this.)
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Storage credential — Databricks acts AS the Access Connector's UAMI
# ---------------------------------------------------------------------------
resource "databricks_storage_credential" "lab" {
  name    = "sc-lab-access-connector"
  comment = "Access Connector UAMI; Storage Blob Data Contributor on ${var.storage_account_name} (Terraform-managed)."

  azure_managed_identity {
    access_connector_id = module.identity.access_connector_id
    managed_identity_id = module.identity.user_assigned_identity_id
  }

  force_destroy = true

  # RBAC propagation on the role assignment can lag by minutes. If the first
  # full apply 403s here, just re-run `terraform apply` — it is safe.
  depends_on = [azurerm_role_assignment.connector_blob_contributor]
}

# ---------------------------------------------------------------------------
# 2. External locations — one per ADLS filesystem
# ---------------------------------------------------------------------------
resource "databricks_external_location" "this" {
  for_each = toset(local.filesystem_names)

  name            = "loc-lab-${each.value}"
  url             = "abfss://${each.value}@${var.storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.lab.name
  comment         = "Lab ${each.value} layer (Terraform-managed)."

  force_destroy = true

  depends_on = [module.storage]
}

# ---------------------------------------------------------------------------
# 3. Catalog + schemas
# ---------------------------------------------------------------------------
# storage_root is REQUIRED here: auto-provisioned metastores have no
# metastore-level root storage, so a catalog without its own managed location
# fails to create. The dedicated `catalog` container (via its external
# location) holds managed tables for the whole catalog.
resource "databricks_catalog" "lab" {
  name         = "lab"
  comment      = "Practice catalog (dev-lab profile, ADR-0006)."
  storage_root = databricks_external_location.this["catalog"].url

  force_destroy = true
}

resource "databricks_schema" "raw" {
  catalog_name = databricks_catalog.lab.name
  name         = "raw"
  comment      = "Landing / bronze-adjacent practice schema."

  force_destroy = true
}

resource "databricks_schema" "curated" {
  catalog_name = databricks_catalog.lab.name
  name         = "curated"
  comment      = "Cleaned / gold-adjacent practice schema."

  force_destroy = true
}

# ---------------------------------------------------------------------------
# 4. Grants — to the deploying user (solo-lab exception, see header)
# ---------------------------------------------------------------------------
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.lab.name

  grant {
    principal  = data.databricks_current_user.me.user_name
    privileges = ["ALL_PRIVILEGES"]
  }
}

resource "databricks_grants" "external_locations" {
  for_each = databricks_external_location.this

  external_location = each.value.name

  grant {
    principal  = data.databricks_current_user.me.user_name
    privileges = ["ALL_PRIVILEGES"]
  }
}
