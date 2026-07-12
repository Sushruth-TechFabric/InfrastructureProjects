# ADR-0005: Version pinning, naming, and tagging conventions

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** Platform (learning build)

## Context

Name-based cross-state lookups (ADR-0001) only work if names are predictable, and
reproducible plans only exist if tool/provider versions are pinned. We needed to
commit to concrete conventions before writing resources.

## Decision

- **Terraform core:** `required_version = ">= 1.9, < 2.0"` (verified against the
  local Terraform **v1.15.7**; the `< 2.0` upper bound guards against a future
  breaking major).
- **Provider:** `azurerm ~> 4.0`, declared in `required_providers`. The
  `databricks` provider is intentionally absent this pass (ADR-0002).
- **Lock file:** commit `.terraform.lock.hcl` per root so every machine/CI run
  resolves identical provider versions.
- **azurerm 4.x note:** the provider requires an explicit `subscription_id`
  (sourced from a variable), and Key Vault uses `rbac_authorization_enabled` (the
  old `enable_rbac_authorization` is deprecated).
- **Naming:** `{type}-{project}-{env}-{region}-{instance}` everywhere, project token
  from the per-root `project` variable (default `dbx`; hub resources add a `hub` function token), region **abbreviation used consistently in
  every name** (current region West US 3 → `wus3`; never the long `westus3`),
  instance `001`. Storage/Key Vault respect Azure length + character limits
  (storage `stdbxdevwus3001`, KV `kv-dbx-dev-wus3-001`).
- **Resource-type prefixes are the Microsoft CAF abbreviations** (verified against
  the CAF list): `rg`, `vnet`, `snet`, `nsg`, `rt`, `peer`, `pip`, `ng`, `afw`,
  `afwp`, `pep` (private endpoint — NOT `pe`), `dbw`, `dbac`, `id`, `kv`, `st`.
  Private DNS zones keep their fixed `privatelink.*` names.
- **Tagging:** every resource carries the required set — `Environment`, `Owner`,
  `CostCenter`, `ManagedBy=terraform`, `Project` — via a single `common_tags` map
  in each root.

## Consequences

- **Positive:** deterministic plans; name-based data-source lookups are reliable;
  cost allocation and ownership are queryable via tags.
- **Trade-offs:** the naming convention is now an API contract — a rename is a
  breaking change for any consumer that looks the resource up by name.
- **Follow-ups:** generate cross-platform provider hashes
  (`terraform providers lock -platform=…`) when CI runs on multiple OSes.

## References

- `docs/architecture/azure-platform-architecture.md` §2
- `.claude/skills/azure-databricks-author-review/references/terraform.md` §2–4
