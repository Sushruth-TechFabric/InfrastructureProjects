# ADR-0011: Account-level UC metastore in shared-services; catalog-level managed storage

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** platform team

## Context

ADR-0001/0002/0008 all deferred the Unity Catalog metastore as "future, in
shared-services". The dev workspace needs to be UC-enabled so catalogs can be
created from the dev root. Constraints:

- The metastore is a Databricks **account** object — one per Azure region per
  account, shared by every workspace in the region. It cannot belong to any
  single environment's state (one state file per deployment boundary).
- The account is **UC auto-enabled**: a regional default metastore is
  auto-provisioned and auto-attaches to new workspaces. dev-lab (ADR-0006)
  deliberately relies on this and manages no metastore. Because dev-lab
  workspaces live in the **same Databricks account**, a westus3 metastore very
  likely already exists — and the one-per-region limit means we cannot create a
  second one.
- Cross-state lookups must use data sources **by name** — never
  `terraform_remote_state`, never hardcoded IDs. The metastore is the first
  cross-state object that is not an Azure resource.
- Open question this ADR settles: metastore-level managed storage
  (`storage_root`) vs catalog-level managed locations owned per environment.

## Decision

1. **The metastore lives in `shared-services/uc.tf`**, created/managed with an
   account-level `databricks.account` provider (host
   `accounts.azuredatabricks.net`, GUID account id, pinned secretless
   `auth_type` — same block as dev's identity layer, ADR-0008). Name:
   `mst-{project}-shared-{region}-{instance}` (`mst-dbx-shared-wus3-001`).
2. **Import-or-create, not create.** The runbook checks for an existing
   regional metastore first; if one exists (expected — auto-provisioned),
   `terraform import` it and let Terraform rename it in place to the convention
   name. `region` is ForceNew: verify it before importing.
3. **No metastore-level `storage_root`. Managed storage is declared per
   catalog, owned by each environment root.** Rationale:
   - **One-state-per-boundary:** a metastore root would land every env's
     managed tables in shared-services-owned storage and force shared-services
     to grow storage + Access Connector + credential infrastructure it should
     not own. With catalog-level storage, each env's data, identity, and
     credential stay inside its own state boundary.
   - **Databricks' current best practice** is metastore-without-root, forcing
     an explicit managed location per catalog.
   - **Matches reality:** auto-provisioned Azure metastores have no root —
     exactly why dev-lab's `lab` catalog sets `storage_root`.
   - **Blast radius:** dev data never lives in shared storage; per-env
     isolation survives a shared-services compromise or teardown.
4. **Cross-state by name, extended to Databricks account objects:** env roots
   resolve the metastore with `data "databricks_metastore"` by `name` via the
   account provider, then attach with `databricks_metastore_assignment`
   (numeric workspace id). The metastore name joins the hub resource names as
   part of the naming contract.
5. **Per-env enablement lives in the env root** (`environments/dev/uc.tf`):
   assignment → storage credential wrapping the Access Connector UAMI → external
   location for a dedicated `catalog` container (`skip_validation = true`,
   because the control plane's create-time probe has no private path to the
   sealed storage account). No `force_destroy` in secure environments. Catalogs
   / schemas / grants remain a future pass (groups only, ADR-0009 pattern).
6. **`prevent_destroy` on the metastore.** It is a shared account object —
   dev-lab attaches to it too. Teardown keeps it:
   `terraform state rm databricks_metastore.this` before a shared-services
   destroy.
7. **Do NOT disable the account's UC auto-enablement / default-metastore
   auto-assignment.** dev-lab depends on auto-attach. Real environments treat
   the assignment as import-or-create instead.

## Consequences

- **Positive:** dev is UC-enabled with a Terraform-managed, convention-named
  metastore; a future `databricks_catalog` in the dev root needs only
  `storage_root = databricks_external_location.catalog.url`. dev-lab behavior
  is unchanged (the metastore it auto-attaches to just gains a managed name).
  The by-name contract now covers the platform's only non-Azure cross-state
  object.
- **Negative / trade-offs:** shared-services applies now require a Databricks
  **account admin** (previously azurerm-only). `terraform destroy` of
  shared-services requires the documented `state rm` step. Auto-attached
  workspaces need a one-time assignment import.
- **Follow-ups:**
  - ~~Set `metastore_owner` to a platform-admin **account group** once one
    exists~~ **Resolved:** `metastore_owner = "grp-dbx-dev-admins"` in
    `shared-services/terraform.tfvars` — the only account-level admin group
    that currently exists (materialized by environments/dev's
    workspace-access module), referenced by name across the state boundary.
    It is env-scoped by name, not a true platform-wide group; swap it for one
    if/when that's created. Bootstrap-order caveat: this metastore is created
    in shared-services BEFORE environments/dev creates that group, so the
    owner must stay `null` on a subscription's very first-ever shared-services
    apply and be set (then re-applied) only after environments/dev pass 2 has
    run at least once.
  - Same treatment for `owner` on UC objects environments/dev itself creates
    (storage credential, external locations, catalogs, schemas): pinned to
    `local.uc_owner` (`environments/dev/uc.tf`), the same admins group,
    resolved in-state via `module.workspace_access.group_display_names`.
  - A future non-account-admin CI principal needs `CREATE STORAGE CREDENTIAL` /
    `CREATE EXTERNAL LOCATION` grants (or metastore-admin) before it can run
    the dev UC pass.
  - Catalogs / schemas / UC grants to the ADR-0008 groups — the next pass.

## References

- `shared-services/uc.tf`, `environments/dev/uc.tf`,
  `docs/runbooks/deploy-dev.md` (import-or-create procedure)
- ADR-0001 (cross-state by name), ADR-0002 (deferred databricks provider),
  ADR-0006 (dev-lab no-metastore stance — still valid for dev-lab),
  ADR-0008 (account provider pattern), ADR-0009 (groups-only grants)
- Architecture doc §Unity Catalog
