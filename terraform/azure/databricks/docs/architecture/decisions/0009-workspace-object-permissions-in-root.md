# ADR-0009: Workspace-object permissions — tfvars grant matrix, owned by the environment root

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** platform team

## Context

ADR-0008 put the identity layer in place: Entra groups synced to the Databricks
account and assigned to the workspace (dev: `grp-dbx-dev-admins` ADMIN,
`grp-dbx-dev-users` USER). But the workspace objects in `workspace-config.tf` —
three cluster policies and the Key Vault-backed secret scope — carried **no
grants**, so only workspace admins could use them; the policies onboarded
nobody. We need to decide *who may use which object*, where that wiring lives,
and how it stays idempotent, under the standing rules: grants to groups only
(AGENTS.md rule 10), least privilege, no environment values in modules
(ADR-0003), config-driven so the pattern ports to staging/prod.

## Decision

1. **Grants live in the environment root** (`workspace-permissions.tf`), not a
   module — despite the "prefer modules" heuristic. They bind root resources
   (policies, scope) to `module.workspace_access` outputs, which is exactly the
   cross-module integrator glue ADR-0003 assigns to the root (precedent: the
   `Storage Blob Data Contributor` grant in `main.tf`). A grants-only module
   would be a valueless pass-through that still needs the root to assemble
   every input.
2. **The matrix is tfvars-driven** via two variables:
   `cluster_policy_can_use = map(policy key => list of identity_groups keys)`
   granted CAN_USE, and `secret_scope_read_groups = list of keys` granted READ.
   Groups are referenced by their **immutable logical key** (e.g. `users`);
   display names resolve through `module.workspace_access.group_display_names`,
   so a `role_token` rename propagates without address churn. Cross-variable
   validation (TF >= 1.9) fails a typo'd key loudly at plan time.
3. **Dev matrix:** `users` gets CAN_USE on personal + shared and READ on the
   scope; the **jobs policy stays admins-only** (job clusters are created by
   automation principals in prod — dev mirrors that posture). **Admins get no
   explicit grants**: workspace admins implicitly manage these objects and
   Terraform cannot lower that, so explicit entries would be redundant noise.
4. **Semantics we lean on:** `databricks_permissions` is *authoritative per
   object* — UI-added grants are reverted on apply (desired convergence) — and
   rejects zero `access_control` blocks, so "admins only" is expressed by an
   *absent* policy key (an empty list is filtered out in a local).
   `databricks_secret_acl` is one entry per (scope, principal), keyed by the
   logical group key.

## Consequences

- **Positive:** adding/removing a group in tfvars converges cleanly on
  re-apply (in-place `access_control` update or single ACL create/destroy, no
  orphans); removing a policy's last grant destroys the permissions object and
  the policy reverts to admins-only; staging/prod reuse the identical files
  and choose their own matrix in tfvars.
- **Negative / trade-offs:** secret ACLs are **not** authoritative for the
  scope — an ACL added out-of-band via the CLI is invisible to `terraform
  plan`; audit occasionally with `databricks secrets list-acls kv-dbx-dev`.
  Grants can transiently fail right after a group's first workspace assignment
  (provider issue #5367 eventual-consistency family) — re-apply converges.
  READ is the only meaningful non-admin ACL on a KV-backed scope (writes go to
  Key Vault), so finer secret tiers require additional scopes, not ACL levels.
- **Follow-ups:** when an automation-principals group exists, grant it the
  jobs policy in tfvars; Unity Catalog grants (SQL `GRANT` to the same groups)
  remain a separate future layer.

## References

- ADR-0003 (module vs root boundary), ADR-0008 (identity layer)
- `environments/dev/workspace-permissions.tf`, `environments/dev/variables.tf`
- Databricks provider: `databricks_permissions` (authoritative), `databricks_secret_acl`
- databricks/terraform-provider-databricks#5367 (assignment eventual consistency)
