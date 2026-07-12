# ADR-0013: Lakebase (managed Postgres / OLTP) in dev

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** Platform (Sushruth)

## Context

Dev needs an OLTP/transactional store alongside the analytics stack. Databricks'
**Lakebase** — serverless managed Postgres — fits: it runs in the
Databricks-managed serverless plane (the plane ADR-0012's NCC gave a private path
to our data), is identity-native (Databricks OAuth, no Postgres passwords), and
maps into Unity Catalog. It is preview / early-GA.

The `databricks` provider (pinned `~> 1.121`, resolved 1.121.0) exposes **two**
Lakebase surfaces, both already present — no provider bump needed:

- **`databricks_database_instance`** — the high-level managed instance:
  `capacity` (`CU_1`..`CU_8`), `node_count`, `retention_window_in_days` (2–35),
  `stopped`, `enable_pg_native_login`, `custom_tags`. Integrates with
  `databricks_permissions` (`database_instance_name`) and Unity Catalog
  (`databricks_database_database_catalog`).
- **`databricks_postgres_project` / `_branch` / `_endpoint` / `_role`** — the
  lower-level Neon primitives: branching, `autoscaling_limit_min_cu` down to 0.5,
  a `suspend_timeout_duration` (true auto-suspend / scale-to-zero), and
  Postgres-native identity roles.

Two forces to resolve: which surface, and how to grant group access under the
platform's secretless + group-only rules.

## Decision

1. **Use `databricks_database_instance`.** It is the platform-consistent surface:
   fewer moving parts, less preview area, and it plugs straight into the existing
   `databricks_permissions` group-grant seam (ADR-0009) and UC. The dev instance
   is `lb-dbx-dev-wus3-001`, `capacity = CU_1`, single node, no readable
   secondaries.

2. **Secretless via `enable_pg_native_login = false`.** Postgres
   username/password auth is turned off entirely; the only way in is a Databricks
   OAuth identity. The resource stores no password and `read_write_dns` is just a
   hostname — nothing sensitive reaches tracked files or state (golden rule,
   AGENTS.md §7).

3. **Access is group-only via `databricks_permissions`** on
   `database_instance_name` — `CAN_MANAGE` / `CAN_USE` resolved through
   `module.workspace_access.group_display_names[<key>]`, the exact ADR-0009
   pattern the SQL warehouse uses. Default matrix: `engineers = CAN_MANAGE`,
   `users` + `bi_users` = `CAN_USE`, admins implicit. A cross-variable validation
   keeps the two lists disjoint.

4. **Dev cost controls without an auto-suspend knob.** The instance surface has
   **no** per-minute suspend timeout (that lives only on `postgres_endpoint`).
   Dev economics therefore come from smallest `capacity` (`CU_1`) + minimum
   `retention_window_in_days` (2) + single node + a `stopped` toggle (pause →
   storage-only billing) + `purge_on_delete = true` for clean teardown.

5. **Enablement is a console prerequisite, not Terraform.** No provider resource
   toggles the Lakebase feature; it is enabled per account/workspace (serverless
   on in-region). Documented as a one-time runbook step (like AIM / the
   metastore); a disabled feature fails create with "feature not enabled."

6. **Opt-in per environment via `lakebase_enabled` (default false).** Not every
   deployment needs OLTP, so the whole file is `count`-gated on that flag —
   turning Lakebase on is a `terraform.tfvars` change, not a code change. dev sets
   it `true`; staging/prod inherit the default (off) until they need it. This is
   the same "toggle in-config" shape as the SQL-warehouse grants, not a separate
   root (contrast ADR-0006's dev-lab, which forks a whole root for its profile).

## Consequences

- **Positive:** OLTP in dev with zero secrets, group-governed access that reuses
  the existing identity seam, and predictable low cost; no new provider, no
  account-scoped plumbing (the instance and its permissions are workspace-scoped).
- **Negative / trade-offs:** no true auto-suspend on this surface — "cheap when
  idle" means *stop-when-idle*, a manual/scheduled `stopped` flip, not automatic
  scale-to-zero. Postgres-native per-role RBAC and DB branching are not modeled.
- **Follow-ups:** if true scale-to-zero (auto-suspend after N seconds idle) or
  DB branching becomes a requirement, revisit with the Neon `postgres_*` surface
  (`autoscaling_limit_min_cu = 0.5` + `suspend_timeout_duration`). Optionally
  register the database into UC via `databricks_database_database_catalog` for
  governed analytics access. Optionally lock the Lakebase endpoint itself behind
  private connectivity (its own NCC/private-link path) — out of scope this pass.

## References

- ADR-0012 (serverless network connectivity — the plane Lakebase runs in)
- ADR-0009 (workspace-object permissions — the group-grant seam reused here)
- ADR-0008 (identity groups owned by the env root)
- `environments/dev/lakebase.tf`; deploy-dev runbook "Lakebase" step
- Databricks: `databricks_database_instance`, `databricks_permissions`
  (`database_instance_name`)
