# ADR-0002: Infra layer first; defer the databricks provider

- **Status:** Accepted
- **Date:** 2026-06-30
- **Deciders:** Platform (learning build)

## Context

The platform spans two provider scopes: `azurerm` (networking, storage, Key Vault,
identity, the workspace resource itself) and `databricks` (cluster policies, IP
access lists, secret scopes, Unity Catalog bindings). The `databricks` provider
needs an authenticated workspace host (and, for Unity Catalog, the account-level
metastore that lives in `shared-services` and uses a different account-level auth
path). Wiring all of that at once would couple the first deploy to identity
federation and account provisioning that aren't in place yet.

## Decision

Deliver the **`azurerm` infrastructure layer first**:

- Spoke networking (VNet injection, NSGs, forced-tunneling route table)
- ADLS Gen2 (hardened, private), Key Vault (private, RBAC)
- Access Connector + user-assigned managed identity + `Storage Blob Data Contributor`
- Databricks workspace (VNet injection + SCC + back-end Private Link)
- Cross-state wiring (peering, DNS links, private endpoints, RBAC)

**Defer** all `databricks`-provider resources — cluster policies, workspace IP
access lists, Key Vault-backed secret scopes, and Unity Catalog metastore
assignment / storage credential / external location / GRANTs — to later passes.

## Consequences

- **Positive:** a clean, deployable foundation with no dependency on databricks
  provider auth or the account-level metastore; smaller blast radius per change;
  each later layer gets its own review and ADR.
- **Trade-offs:** the workspace is not yet "hardened to least functionality" — no
  cluster policy forces VNet/SCC on user-created clusters, and the internet-facing
  front-end is not yet narrowed by an IP access list. These are **known gaps until
  the next pass** and must not be treated as done.
- **Follow-ups:** next pass adds the databricks provider + cluster policies + IP
  access list + secret scope; a subsequent pass adds Unity Catalog.

## References

- `docs/architecture/azure-platform-architecture.md` §4 (workspace governance)
- `.claude/skills/azure-databricks-iac/references/databricks.md` §8–9
