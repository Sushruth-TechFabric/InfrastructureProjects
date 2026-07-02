# Architecture Decision Records (ADRs)

This directory captures the **decisions made while building the platform** — the
"why", not just the "what". The canonical architecture reference
([`../azure-platform-architecture.md`](../azure-platform-architecture.md)) states the
target design; these ADRs record the concrete choices, trade-offs, and constraints we hit
while implementing it, so future work (human or AI agent) has the reasoning as context.

## Index

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-minimal-shared-services-and-cross-state-data-sources.md) | Minimal shared-services + cross-state via Azure data sources | Accepted |
| [0002](0002-infra-layer-first-defer-databricks-provider.md) | Infra layer first; defer the databricks provider | Accepted |
| [0003](0003-module-vs-root-boundary.md) | Module vs. environment-root boundary | Accepted |
| [0004](0004-nat-gateway-on-firewall-subnet-non-zonal.md) | NAT Gateway on the firewall subnet (non-zonal firewall) | Accepted |
| [0005](0005-version-pinning-and-naming-tagging.md) | Version pinning, naming, and tagging conventions | Accepted |
| [0006](0006-cost-optimized-lab-profile.md) | Cost-optimized dev-lab profile (design now, build later) | Proposed |

## How to add an ADR

1. Copy [`0000-adr-template.md`](0000-adr-template.md) to `NNNN-short-title.md`
   (next number, kebab-case title).
2. Fill in Status / Context / Decision / Consequences. Keep it to ~1 screen.
3. Add a row to the index table above.
4. ADRs are immutable once Accepted — to change a decision, write a new ADR that
   **supersedes** the old one and update both Status fields.

## Status values

`Proposed` → `Accepted` → (`Superseded by ADR-NNNN` | `Deprecated`).
