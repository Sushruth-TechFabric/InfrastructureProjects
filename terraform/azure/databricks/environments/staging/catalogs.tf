# =============================================================================
# environments/dev — UNITY CATALOG CATALOGS / SCHEMAS / GRANTS (data-driven)
# -----------------------------------------------------------------------------
# Catalogs and schemas are CONFIG, not hand-written resource blocks: add or
# remove one by editing terraform.tfvars and re-applying — no .tf edits for a
# routine new schema. Each catalog/schema maps to a storage container (an
# external location created in uc.tf) so managed-table data lands on the right
# physical path (bronze/silver/gold/catalog).
#
# Grants go to GROUPS only (AGENTS.md rule 10), resolved via
# module.workspace_access.group_display_names — never a raw UPN and never
# data.databricks_current_user (that is dev-lab's documented solo-lab
# exception, ADR-0006, which does NOT travel to a multi-user environment).
#
# databricks_grants is AUTHORITATIVE per object: the grant blocks here are the
# complete non-owner grant set after apply — UI-added grants are reverted on
# the next apply (drift converges to code). The admins group takes no explicit
# entry because it OWNS every object here (owner = local.uc_owner, uc.tf) and
# owners hold all privileges on what they own. Workspace admin alone confers
# NO implicit UC data privileges — only metastore admins and object owners
# manage securables — so ownership, not admin status, is what carries this.
#
# NO force_destroy anywhere (unlike dev-lab): removing a map entry produces a
# real destroy plan, and if the object still holds data/grants the provider
# refuses — the intended guardrail, not a bug.
# =============================================================================

variable "catalogs" {
  type = map(object({
    comment           = string
    storage_container = string # which external location backs the catalog's managed storage
    schemas = map(object({
      comment           = string
      storage_container = optional(string) # set = schema gets its OWN storage_root; omit = inherit catalog's
    }))
  }))
  description = <<-EOT
    Unity Catalog catalogs and their schemas for THIS environment. Map keys are
    the catalog / schema NAMES. storage_container (catalog- and optional
    schema-level) must be one of the external locations uc.tf creates
    (bronze | silver | gold | catalog). A schema that omits storage_container
    inherits the catalog's managed storage. Add/remove a catalog or schema by
    editing this map and re-applying.
  EOT
  default     = {}

  validation {
    condition = alltrue(flatten([
      for _, cat in var.catalogs : [
        contains(["bronze", "silver", "gold", "catalog"], cat.storage_container),
        [
          for _, s in cat.schemas :
          s.storage_container == null || contains(["bronze", "silver", "gold", "catalog"], s.storage_container)
        ]
      ]
    ]))
    error_message = "Every storage_container (catalog- or schema-level) must be one of the external locations uc.tf creates: bronze, silver, gold, catalog."
  }
}

variable "catalog_grants" {
  type        = map(map(list(string))) # catalog name => identity_groups key => privileges
  description = <<-EOT
    Catalog-level UC privileges: catalog name (must be a key of var.catalogs)
    => identity_groups key => list of privileges (e.g. USE_CATALOG). Grants go
    to GROUPS only. AUTHORITATIVE per catalog: grants made in the UI but not
    listed here are removed on the next apply.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for _, grants in var.catalog_grants : alltrue([
        for g in keys(grants) : contains(keys(var.identity_groups), g)
      ])
    ])
    error_message = "Every group referenced in catalog_grants must be a key of identity_groups (use the logical key, e.g. \"engineers\", not the display name)."
  }

  validation {
    condition = alltrue(flatten([
      for _, grants in var.catalog_grants : [
        for _, privileges in grants : length(privileges) > 0
      ]
    ]))
    error_message = "catalog_grants entries may not have an empty privilege list — remove the group key instead of granting []. Databricks rejects an empty privileges list at apply with an opaque error."
  }

  validation {
    condition = alltrue([
      for cat_key, _ in var.catalog_grants : contains(keys(var.catalogs), cat_key)
    ])
    error_message = "Every catalog_grants key must be a key of var.catalogs."
  }
}

variable "schema_grants" {
  type        = map(map(list(string))) # "catalog.schema" => identity_groups key => privileges
  description = <<-EOT
    Schema-level UC privileges: "catalog.schema" (both must exist in
    var.catalogs) => identity_groups key => list of privileges (e.g.
    USE_SCHEMA, SELECT, MODIFY, CREATE_TABLE). Grants go to GROUPS only.
    AUTHORITATIVE per schema.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for _, grants in var.schema_grants : alltrue([
        for g in keys(grants) : contains(keys(var.identity_groups), g)
      ])
    ])
    error_message = "Every group referenced in schema_grants must be a key of identity_groups (use the logical key, e.g. \"bi_users\", not the display name)."
  }

  validation {
    condition = alltrue(flatten([
      for _, grants in var.schema_grants : [
        for _, privileges in grants : length(privileges) > 0
      ]
    ]))
    error_message = "schema_grants entries may not have an empty privilege list — remove the group key instead of granting []. Databricks rejects an empty privileges list at apply with an opaque error."
  }

  validation {
    condition = alltrue([
      for key, _ in var.schema_grants :
      contains(keys(var.catalogs), split(".", key)[0]) &&
      length(split(".", key)) == 2 &&
      contains(keys(var.catalogs[split(".", key)[0]].schemas), split(".", key)[1])
    ])
    error_message = "Every schema_grants key must be \"catalog.schema\" where catalog is a key of var.catalogs and schema is a key of that catalog's schemas."
  }
}

locals {
  # One lookup over BOTH external-location resources (the standalone `catalog`
  # and the `for_each` bronze/silver/gold), so a container name resolves to its
  # URL regardless of which resource created it.
  uc_external_locations = merge(
    { catalog = databricks_external_location.catalog },
    databricks_external_location.layers,
  )

  # Flatten catalog -> schema into "catalog.schema" keys for a single for_each,
  # carrying the parent catalog / schema names alongside each schema's config.
  catalog_schema_pairs = merge([
    for cat_key, cat in var.catalogs : {
      for schema_key, schema in cat.schemas :
      "${cat_key}.${schema_key}" => merge(schema, {
        catalog_key = cat_key
        schema_key  = schema_key
      })
    }
  ]...)
}

# ---------------------------------------------------------------------------
# Catalogs — one per var.catalogs entry, storage_root on its container
# ---------------------------------------------------------------------------
resource "databricks_catalog" "this" {
  for_each = var.catalogs

  name         = each.key
  comment      = each.value.comment
  storage_root = local.uc_external_locations[each.value.storage_container].url
  owner        = local.uc_owner # rule 10: admins group, not the deploying individual (uc.tf)

  # ISOLATED (not the OPEN default): the metastore is SHARED across every
  # workspace in the region (shared-services/uc.tf), so an OPEN catalog would
  # be visible from dev-lab or any future workspace on that metastore —
  # leaking the dev environment boundary. The workspace_binding below grants
  # dev's own access back.
  isolation_mode = "ISOLATED"

  # Metastore assignment + the storage credential/external locations must exist
  # first; the storage_root reference already edges to the external location.
  depends_on = [databricks_metastore_assignment.this]
}

# Pin each catalog to THIS workspace only — ISOLATED alone does not grant
# access, it just closes the OPEN default; this binding is what makes the
# catalog usable from the dev workspace.
resource "databricks_workspace_binding" "catalog" {
  for_each = var.catalogs

  securable_name = databricks_catalog.this[each.key].name
  securable_type = "catalog"
  workspace_id   = module.databricks_workspace.workspace_resource_id
}

# ---------------------------------------------------------------------------
# Schemas — one per (catalog, schema) pair; own storage_root when configured
# ---------------------------------------------------------------------------
resource "databricks_schema" "this" {
  for_each = local.catalog_schema_pairs

  catalog_name = databricks_catalog.this[each.value.catalog_key].name
  name         = each.value.schema_key
  comment      = each.value.comment
  owner        = local.uc_owner # rule 10: admins group, not the deploying individual (uc.tf)

  # Explicit per-schema physical storage when the config sets its own
  # container; null = inherit the catalog's managed storage.
  storage_root = each.value.storage_container != null ? local.uc_external_locations[each.value.storage_container].url : null
}

# ---------------------------------------------------------------------------
# Grants — catalog- and schema-level, to GROUPS only
# ---------------------------------------------------------------------------
resource "databricks_grants" "catalog" {
  for_each = { for k, v in var.catalog_grants : k => v if length(v) > 0 }

  catalog = databricks_catalog.this[each.key].name

  # Belt and braces: the variable validation above already rejects an empty
  # privilege list, but this filter protects any future composed/merged map
  # that bypasses that validation — an empty privileges = [] block is rejected
  # by the Databricks API at apply with an opaque error.
  dynamic "grant" {
    for_each = { for gk, p in each.value : gk => p if length(p) > 0 }
    content {
      principal  = module.workspace_access.group_display_names[grant.key]
      privileges = distinct(grant.value)
    }
  }

  # group_display_names is derived from azuread_group alone; without this the
  # grant can race the account->workspace group-sync chain (same reasoning as
  # databricks_permissions.cluster_policy in workspace-permissions.tf).
  depends_on = [module.workspace_access]
}

resource "databricks_grants" "schema" {
  for_each = { for k, v in var.schema_grants : k => v if length(v) > 0 }

  # Full "catalog.schema" name, constructed explicitly from the resolved
  # resource names rather than relying on a computed id shape.
  schema = "${databricks_catalog.this[local.catalog_schema_pairs[each.key].catalog_key].name}.${databricks_schema.this[each.key].name}"

  # See the catalog grants filter above for why this exists in addition to the
  # variable validation.
  dynamic "grant" {
    for_each = { for gk, p in each.value : gk => p if length(p) > 0 }
    content {
      principal  = module.workspace_access.group_display_names[grant.key]
      privileges = distinct(grant.value)
    }
  }

  depends_on = [module.workspace_access]
}
