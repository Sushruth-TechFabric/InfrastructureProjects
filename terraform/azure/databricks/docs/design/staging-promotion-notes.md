# Staging promotion notes (E7, 2026-07-10 review)

The design claim in `docs/architecture/azure-platform-architecture.md` is that
promoting dev to a new environment is **a `terraform.tfvars` change, not a code
change**. This was untested — `environments/staging/*.tf` were 0-byte stubs.
This note records what it took to make that claim true, as the remaining
portability debt list the review asked for.

## What was copied verbatim

Every `.tf` file in `environments/staging/` is a byte-for-byte copy of the
corresponding file in `environments/dev/` at the time of this pass (after the
2026-07-10 remediation fixes below), except `backend.tf` (state key differs —
same partial-config pattern, see E1) and the `.terraform.lock.hcl` (copied
as-is; identical provider set):

`providers.tf`, `variables.tf`, `main.tf`, `uc.tf`, `catalogs.tf`,
`workspace-config.tf`, `workspace-permissions.tf`, `sql-warehouse.tf`,
`lakebase.tf`, `network-connectivity.tf`, `outputs.tf`.

**No code edit was required to make this copy work.** Everything that differs
between dev and staging lives in `terraform.tfvars` (see
`terraform.tfvars.example`) and `backend.hcl` (per-deployment, gitignored).

## Why this was possible now, and wasn't before

Two 2026-07-10 review findings were **prerequisites**, fixed as part of this
same pass, specifically because a hardcoded value in dev's code would have
made a verbatim copy silently point staging at DEV's resources instead of
its own:

- **E3 — derived cross-state defaults.** `hub_resource_group_name`,
  `metastore_name`, and `storage_account_name` used to default to dev's own
  hardcoded names (`rg-networking-dbx-shared-wus3-001`,
  `mst-dbx-shared-wus3-001`, `stdbxdevwus3001`). A verbatim copy into staging
  would have derived storage names from the *default*, not from staging's own
  `environment = "staging"` value — i.e. staging would have silently tried to
  create/attach the same storage account name dev uses. Fixed by deriving all
  three from the naming convention (`local.effective_*` in `main.tf`) with
  `null` defaults, so each environment's own `project`/`environment`/
  `region_abbrev`/`instance` inputs produce the right name automatically.
- **E1 — partial backend config.** `backend.tf` used to hardcode dev's actual
  state resource group + storage account name. A verbatim copy would have
  pointed staging's `terraform init` at DEV'S STATE FILE — the worst possible
  portability failure (two environments sharing one state). Fixed by making
  every root's `backend.tf` an empty `backend "azurerm" {}` + a per-deployment
  gitignored `backend.hcl`.

Also inherited "for free" because they were fixed in dev's code before this
copy was made (so staging never had the bug to begin with):

- **C9** — `module.workspace_access` now `depends_on` the metastore
  assignment, avoiding an apply-order race on any account that doesn't
  auto-attach a default metastore (staging's account almost certainly won't
  have staging pre-attached the way a long-lived dev sandbox might).
- **D6** — empty-privilege grant entries are now rejected by variable
  validation and filtered defensively in the grant `dynamic` blocks, so a
  typo'd `terraform.tfvars.example` entry fails with a clear message instead
  of an opaque Databricks API error at apply.

## Remaining known gaps (not blockers, tracked here so they aren't lost)

These are pre-existing dev findings from the 2026-07-10 review that were
**not** in scope for this pass (not deploy blockers) and therefore now exist
in staging too, verbatim:

- **D5 (not implemented):** `lakebase.tf` hardcodes `purge_on_delete = true`
  with no per-environment override. Irrelevant to staging today
  (`lakebase_enabled = false` in `terraform.tfvars.example`), but MUST be
  fixed with a `lakebase_purge_on_delete` variable (default `false`) before
  anyone flips Lakebase on in staging or prod.
- **A2 (not implemented):** the NCC private-endpoint approval logic in
  `network-connectivity.tf` approves ANY `Pending` connection on the storage
  account / Key Vault, not just ones matching this environment's NCC rules.
  Copied verbatim into staging — same exposure, doubled.
- **D1/D2/D3 (not implemented):** cluster-policy Spark-version pinning is
  cosmetic (`type: unlimited`), fixed-size clusters bypass the worker caps,
  and there is no workspace hardening file (token lifetime, audit logs, DBFS
  browser, etc.). Copied verbatim into staging.
- **B2 (not implemented):** `databricks_account_id` validation still accepts
  the all-zeros placeholder GUID.

None of these block a first `terraform plan`/`apply` of staging — they are
security/hardening debt inherited from dev, not staging-specific breakage.

## Validation performed

- `terraform fmt -recursive` across `environments/staging`.
- `terraform init -backend=false` + `terraform validate` in
  `environments/staging` (no real backend/credentials available in this
  session — validate only checks internal config consistency, not that the
  hub/metastore actually exist).
- Did **not** run `terraform plan` or `apply` against real Azure — no
  subscription/credentials in this session, and the runbook explicitly says
  not to for a first-time environment build. The `terraform.tfvars.example`
  values (CIDR `10.11.0.0/20`, `staging` env token) still need review by
  someone with real Azure/Databricks account access before first apply.
