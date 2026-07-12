# ADR-0008: Identity layer — Entra groups + AIM sync, owned by the environment root

- **Status:** Accepted (supersedes the "Entra→account group sync lives in
  shared-services" scope line of [ADR-0001](0001-minimal-shared-services-and-cross-state-data-sources.md)/AGENTS.md)
- **Date:** 2026-07-10
- **Deciders:** Platform (learning build)

## Context

Nothing in Terraform managed who can access a workspace. We need: Entra ID
groups as the source of truth, declarative membership, propagation to the
Databricks account, and per-workspace ADMIN/USER assignment — fully
convergent (add/remove/rename + re-apply, no duplicates, no orphans, removal
revokes). The account has **Automatic Identity Management (AIM)** available
(GA; default-on for accounts created after Aug 2025), which syncs Entra
users/groups/SPs into Databricks at auth time.

## Decision

1. **AIM is the sync mechanism** — Terraform does NOT mirror users or
   memberships into Databricks (no `databricks_user`, no
   `databricks_group_member`). Rejected: the Entra SCIM provisioning
   connector (needs a SCIM token — a secret — and lives outside Terraform)
   and a full Terraform SCIM mirror (fights AIM, duplicates membership
   management). **AIM enabled is a hard prerequisite** (account console →
   Security → User provisioning).
2. **Identity is environment-owned.** Groups are env/workspace-specific
   (env→workspace is 1:1), so the whole chain lives in the env root's state
   via the reusable `modules/workspace-access` blueprint — not in
   shared-services. The old shared-services scope assumed deploy-once SCIM
   machinery; under AIM none exists. Bonus: no cross-state lookup contract —
   shells and assignments reference each other directly in one state. Only
   genuinely cross-env identity (future UC metastore, platform-wide groups,
   CI service principals) would belong in shared-services.
3. **Each group is three linked resources:** authoritative `azuread_group`
   (members list IS the group; portal additions reverted; PR is the only way
   in) → thin account-level `databricks_group` **materialization shell**
   (`external_id` = Entra objectId — AIM's identity link, prevents duplicate
   principals; `force = true` adopts pre-existing) →
   `databricks_mws_permission_assignment` (`["ADMIN"]`/`["USER"]`). The shell
   is required because the assignment API cannot reference an Entra-only
   group (provider issue #5414) and AIM's `resolveByExternalId` API has no
   Terraform support yet.
4. **Guardrails baked into the module:** `prevent_duplicate_names = true`
   (Entra names aren't unique — a cold apply against an existing same-name
   group fails, forcing `terraform import`, instead of silently creating a
   duplicate); pinned provider `auth_type` (`azure-cli` locally,
   `github-oidc-azure` in CI — no silent SDK auth fallback, no PATs);
   display names derived as `grp-{project}-{env}-{role}` (naming-convention
   deviation: no region/instance — groups are tenant-scoped).
5. **Rules of use:** map keys are immutable logical handles (renaming one
   recreates the group → new Databricks-internal principal id → cascades into
   assignments and future UC grants; rename via `role_token` instead, which
   updates in place). Keep groups **flat** — AIM honors nested-group access
   but never provisions children, so they're invisible to Terraform/UC
   grants. Deleting a group is a **breaking change**: its Entra object id may
   be referenced elsewhere (the `resource_group_reader_groups` Azure-plane
   RBAC grants, UC grants) — sweep references first, especially in
   staging/prod.

## Consequences

- **Positive:** config is the single access truth (Entra-side manual adds are
  reverted; Databricks-side member edits are impossible — AIM groups are
  read-only in the console); removal revokes without orphans (`destroy`
  cleans assignment → shell → group, which AIM itself never garbage-collects);
  no secrets anywhere (account id is an identifier; auth rides `az login` /
  OIDC).
- **Negative / trade-off:** revocation at the workspace is not instant —
  Entra membership changes land at apply, but Databricks refreshes membership
  on auth activity (≤5 min browser login, ≤40 min token/job auth) plus
  residual session lifetime. Assignment creation can flake with "Principal
  not in workspace" (#5367, eventual consistency) — re-apply converges. The
  deployer must be a Databricks **account admin** (workspace admin is not
  enough).
- **Deferred:** workload/CI service principals (AIM provisions SPs lazily on
  first auth; a proactive `databricks_service_principal` registration will be
  needed), UC metastore. Azure-plane RBAC has since landed: the env root's
  `resource_group_reader_groups` grants Reader on the function RGs to these
  groups.

## References

- AIM overview / migrate-to-AIM (MS Learn):
  <https://learn.microsoft.com/en-us/azure/databricks/admin/users-groups/automatic-identity-management/>
- Provider issues: assignment can't reference Entra-only principals
  (<https://github.com/databricks/terraform-provider-databricks/issues/5414>),
  assignment eventual consistency
  (<https://github.com/databricks/terraform-provider-databricks/issues/5367>)
- `modules/workspace-access` (implementation), `environments/dev/providers.tf`
  (account-level provider), `docs/runbooks/deploy-dev.md` (bootstrap +
  verification)
