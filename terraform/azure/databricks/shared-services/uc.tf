# =============================================================================
# shared-services — UNITY CATALOG METASTORE (account-level, one per region)
# -----------------------------------------------------------------------------
# The metastore is a Databricks ACCOUNT object — one per Azure region per
# account, shared by every workspace in that region — so it lives in this
# deploy-once root, never in an environment root (AGENTS.md / ADR-0011).
#
# IMPORT-OR-CREATE (runbook, deploy-dev.md step 2): the account is UC
# auto-enabled, so an auto-provisioned westus3 metastore very likely already
# exists (dev-lab workspaces attach to it). Azure allows only ONE per region —
# check first; if it exists, `terraform import` it and let Terraform rename it
# in place to the convention name below. Only create if the region has none.
#
# NO storage_root — on purpose (ADR-0011). Managed-table storage is declared
# per CATALOG, owned by each environment root: a metastore-level root would
# land every env's managed tables in shared-services-owned storage, coupling
# the data plane across state boundaries. (It also matches the auto-provisioned
# metastore, which has no root.)
#
# prevent_destroy: this is a shared account object — dev-lab and every future
# env workspace hang off it. Teardown keeps it: `terraform state rm
# databricks_metastore.this` before a shared-services destroy (runbook step 6).
#
# Tags rule (AGENTS.md 4) is N/A here: not an Azure resource — metastores take
# no tags.
# =============================================================================

locals {
  # Naming convention {type}-{project}-{env}-{region}-{instance}, env token
  # "shared" like every hub resource. This NAME is the cross-state contract:
  # env roots resolve the metastore by name via data "databricks_metastore"
  # (the by-name rule extended to the one non-Azure cross-state object).
  metastore_name = "mst-${var.project}-shared-${var.region_abbrev}-${var.instance}"
}

resource "databricks_metastore" "this" {
  provider = databricks.account

  name   = local.metastore_name # mst-dbx-shared-wus3-001 — load-bearing, see above
  region = var.location         # ForceNew — verify the imported metastore's region first
  owner  = var.metastore_owner  # grp-dbx-dev-admins (rule 10); null = unmanaged (creator on create, as-is on import) — see BOOTSTRAP ORDER CAVEAT in terraform.tfvars

  # NO storage_root (ADR-0011): catalog-level managed storage, owned per env.

  lifecycle {
    prevent_destroy = true
  }
}
