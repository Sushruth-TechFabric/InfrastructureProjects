# =============================================================================
# environments/dev — UNITY CATALOG ENABLEMENT (assignment + storage plumbing)
# -----------------------------------------------------------------------------
# The metastore itself is ACCOUNT-level and lives in shared-services (ADR-0011).
# This root does the per-environment half:
#   metastore assignment (attach the shared metastore to THIS workspace)
#     → storage credential (wraps the Access Connector UAMI — secretless)
#     → external location for the `catalog` container (future managed storage)
#
# STOPS THERE on purpose: catalogs / schemas / grants are a future pass, gated
# on group-based grants (ADR-0009 pattern — groups only, never individuals).
# The metastore has NO root storage (ADR-0011), so that future catalog must set
# storage_root = the external location URL below; everything it needs exists
# after this file applies.
#
# Unlike dev-lab, NO force_destroy anywhere: in a secure environment a destroy
# that would take data-bearing UC objects with it SHOULD wedge until a human
# decides.
# =============================================================================

locals {
  # UC object ownership defaults to the DEPLOYING INDIVIDUAL unless set
  # explicitly — a rule-10 violation (groups, not individuals) and a bus-factor
  # risk if that person leaves. Every UC-managed object this root creates
  # (storage credential, external locations, catalogs, schemas — catalogs.tf)
  # pins owner to the admins group instead, so ownership is deterministic
  # regardless of who runs `terraform apply`. "admins" must be a key of
  # var.identity_groups (enforced by validation in variables.tf).
  uc_owner = module.workspace_access.group_display_names["admins"]
}

# The shared metastore, resolved BY NAME via the account provider — the same
# cross-state contract as the hub DNS zones (never remote_state, never a
# hardcoded id). Until shared-services is applied, plan fails "not found":
# that is the deploy-order contract working as designed.
data "databricks_metastore" "this" {
  provider = databricks.account
  name     = local.effective_metastore_name
}

# Attach the shared metastore to this workspace (account-level operation).
# NOTE: workspace_resource_id is the NUMERIC workspace id — not workspace_id,
# which is the ARM resource id. If the workspace was already auto-attached to
# the regional default metastore, IMPORT this instead of relying on create:
#   terraform import "databricks_metastore_assignment.this" "<workspace_id>|<metastore_id>"
resource "databricks_metastore_assignment" "this" {
  provider = databricks.account

  metastore_id = data.databricks_metastore.this.id
  workspace_id = module.databricks_workspace.workspace_resource_id
}

# ---------------------------------------------------------------------------
# Storage credential — Databricks acts AS the Access Connector's UAMI
# ---------------------------------------------------------------------------
# Credential names are METASTORE-scoped: the env token in the name keeps every
# environment's credential unique on the shared metastore.
resource "databricks_storage_credential" "this" {
  name    = "sc-${local.name_suffix}"
  comment = "Access Connector UAMI; Storage Blob Data Contributor on ${local.effective_storage_account_name} (Terraform-managed)."
  owner   = local.uc_owner

  azure_managed_identity {
    access_connector_id = module.identity.access_connector_id
    managed_identity_id = module.identity.user_assigned_identity_id
  }

  # ISOLATED (not the OPEN default): the metastore is SHARED across every
  # workspace in the region (shared-services/uc.tf), so an OPEN credential
  # would be usable from dev-lab or any future workspace on that metastore —
  # leaking the dev environment boundary. The workspace_binding below is what
  # actually grants dev's access back; isolation_mode just closes the OPEN
  # default first.
  isolation_mode = "ISOLATION_MODE_ISOLATED"

  # RBAC propagation on the role assignment can lag by minutes. If the first
  # apply 403s here, just re-run `terraform apply` — it is safe. The assignment
  # dependency is load-bearing: workspace-level UC APIs only work once the
  # workspace is attached to the metastore.
  depends_on = [
    azurerm_role_assignment.connector_blob_contributor,
    databricks_metastore_assignment.this,
  ]
}

# Pin the credential to THIS workspace only. Required because isolation_mode
# alone does not grant access — ISOLATED with zero bindings is unusable, and
# ISOLATED still defaults to visible-nowhere until a binding names the
# workspace explicitly.
resource "databricks_workspace_binding" "storage_credential" {
  securable_name = databricks_storage_credential.this.name
  securable_type = "storage_credential"
  workspace_id   = module.databricks_workspace.workspace_resource_id
}

# ---------------------------------------------------------------------------
# External location — managed-table storage for the future dev catalog
# ---------------------------------------------------------------------------
# skip_validation is REQUIRED here, not a shortcut: this ADLS account has
# public network access DISABLED, and UC's create-time validation probe comes
# from the Databricks control plane, which has no private path to it. Real
# access flows through the VNet private endpoints at first cluster use.
resource "databricks_external_location" "catalog" {
  name            = "loc-catalog-${local.name_suffix}"
  url             = "abfss://catalog@${local.effective_storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  comment         = "Managed-table storage root for the dev catalog (ADR-0011)."
  owner           = local.uc_owner

  skip_validation = true

  # ISOLATED, same reasoning as the storage credential above: the metastore is
  # shared, so OPEN would expose this external location to every workspace on
  # it, not just dev. Bound back to dev via the workspace_binding below.
  isolation_mode = "ISOLATION_MODE_ISOLATED"

  depends_on = [module.storage, azurerm_private_endpoint.adls_dfs]
}

resource "databricks_workspace_binding" "loc_catalog" {
  securable_name = databricks_external_location.catalog.name
  securable_type = "external_location"
  workspace_id   = module.databricks_workspace.workspace_resource_id
}

# ---------------------------------------------------------------------------
# External locations — bronze / silver / gold medallion layers
# ---------------------------------------------------------------------------
# The `catalog` container above holds the catalog's managed-table storage; the
# three medallion containers get their own external locations so each schema
# can bind to its own physical storage path (see catalogs.tf). Same
# skip_validation reasoning as loc-catalog: ADLS public access is off and the
# control plane has no private path to probe at create time.
#
# NO force_destroy (unlike dev-lab): a destroy that would strand data-bearing
# UC objects should wedge until a human confirms.
resource "databricks_external_location" "layers" {
  for_each = toset(["bronze", "silver", "gold"])

  name            = "loc-${each.value}-${local.name_suffix}"
  url             = "abfss://${each.value}@${local.effective_storage_account_name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
  comment         = "${title(each.value)} layer storage (Terraform-managed)."
  owner           = local.uc_owner

  skip_validation = true

  # ISOLATED — same shared-metastore reasoning as loc-catalog above.
  isolation_mode = "ISOLATION_MODE_ISOLATED"

  depends_on = [module.storage, azurerm_private_endpoint.adls_dfs]
}

resource "databricks_workspace_binding" "layers" {
  for_each = databricks_external_location.layers

  securable_name = each.value.name
  securable_type = "external_location"
  workspace_id   = module.databricks_workspace.workspace_resource_id
}
