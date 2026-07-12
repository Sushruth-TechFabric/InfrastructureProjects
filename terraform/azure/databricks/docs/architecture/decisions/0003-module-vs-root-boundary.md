# ADR-0003: Module vs. environment-root boundary

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** Platform (learning build)

## Context

We need a consistent rule for what goes in a reusable `modules/*` blueprint versus
what goes in an `environments/<env>` root. Getting this wrong either leaks
environment values into shared code (breaks reuse) or scatters cross-cutting glue
across modules (hard to read/audit).

## Decision

- **Modules are blueprints.** They create self-contained resources, take all
  environment-specific inputs as variables (no defaults on required inputs), and
  expose ids/names via outputs. Modules never reference the hub or another module.
  Modules built: `networking`, `storage`, `key-vault`, `identity`,
  `databricks-workspace`.
- **The environment root is the integrator.** It resolves hub resources by name
  (data sources), creates function-based resource groups, instantiates modules,
  and owns **all cross-state wiring**: VNet peering, Private DNS zone links,
  private endpoints (the PE + DNS-zone-group pattern repeated once per PaaS
  service), and RBAC role assignments.

Specifically, two things that could have gone in a module were deliberately kept in
the root: (a) the `Storage Blob Data Contributor` grant to the Access Connector
identity (needs the storage scope, keeps `identity` scope-agnostic), and (b) all
private endpoints (they depend on both the spoke PE subnet and the hub DNS zones).

## Consequences

- **Positive:** modules are reusable across dev/staging/prod unchanged; every cross-
  state dependency is visible in one file (`environments/<env>/main.tf`); the
  private-endpoint pattern is shown once and repeated, which is good for learning.
- **Trade-offs:** the env root is larger and does more; some coupling logic isn't
  reusable (acceptable — it's inherently environment-specific).

## References

- `docs/architecture/azure-platform-architecture.md` §1
- `.claude/skills/azure-databricks-author-review/references/terraform.md` §1–3
