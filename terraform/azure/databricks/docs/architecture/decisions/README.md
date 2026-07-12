# Architecture Decision Records (ADRs)

This directory captures the **decisions made while building the platform** — the
"why", not just the "what". The canonical architecture reference
([`../azure-platform-architecture.md`](../azure-platform-architecture.md)) states the
target design; these ADRs record the concrete choices, trade-offs, and constraints we hit
while implementing it, so future work (human or AI agent) has the reasoning as context.

## Index

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-minimal-shared-services-and-cross-state-data-sources.md) | Minimal shared-services + cross-state via Azure data sources | Accepted (partially superseded by 0007) |
| [0002](0002-infra-layer-first-defer-databricks-provider.md) | Infra layer first; defer the databricks provider | Accepted |
| [0003](0003-module-vs-root-boundary.md) | Module vs. environment-root boundary | Accepted |
| [0004](0004-nat-gateway-on-firewall-subnet-non-zonal.md) | NAT Gateway on the firewall subnet (non-zonal firewall) | Accepted (dormant — see 0007) |
| [0005](0005-version-pinning-and-naming-tagging.md) | Version pinning, naming, and tagging conventions | Accepted |
| [0006](0006-cost-optimized-lab-profile.md) | Cost-optimized dev-lab profile | Accepted (IP access list clause superseded by 0010) |
| [0007](0007-nat-gateway-nsg-egress-for-dev.md) | NAT Gateway + NSG egress for dev; Azure Firewall optional | Accepted |
| [0008](0008-aim-identity-layer.md) | Identity layer — Entra groups + AIM sync, owned by the environment root | Accepted |
| [0009](0009-workspace-object-permissions-in-root.md) | Workspace-object permissions — tfvars grant matrix, owned by the environment root | Accepted |
| [0010](0010-remove-workspace-ip-access-lists.md) | Remove workspace front-end IP access lists (Entra ID-only gating) | Accepted |
| [0011](0011-account-metastore-in-shared-services.md) | Account-level UC metastore in shared-services; catalog-level managed storage | Accepted |
| [0012](0012-serverless-network-connectivity.md) | Serverless private connectivity (NCC) owned by the environment root | Accepted |
| [0013](0013-lakebase-dev-oltp.md) | Lakebase (managed Postgres / OLTP) in dev | Accepted |

## How to add an ADR

1. Copy [`0000-adr-template.md`](0000-adr-template.md) to `NNNN-short-title.md`
   (next number, kebab-case title).
2. Fill in Status / Context / Decision / Consequences. Keep it to ~1 screen.
3. Add a row to the index table above.
4. ADRs are immutable once Accepted — to change a decision, write a new ADR that
   **supersedes** the old one and update both Status fields.

## Status values

`Proposed` → `Accepted` → (`Superseded by ADR-NNNN` | `Deprecated`).
