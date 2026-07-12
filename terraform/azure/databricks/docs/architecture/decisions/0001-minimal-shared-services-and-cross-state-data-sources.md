# ADR-0001: Minimal shared-services + cross-state via Azure data sources

- **Status:** Accepted — **partially superseded by
  [ADR-0007](0007-nat-gateway-nsg-egress-for-dev.md)** (2026-07-07): the hub firewall
  chain is now optional (`deploy_firewall`, default off) and dev no longer peers to the
  hub or resolves the firewall; dev's only hub dependency is the four Private DNS zones.
  The cross-state-by-name mechanism (the core of this ADR) is unchanged.
  **Also partially superseded by [ADR-0008](0008-aim-identity-layer.md)** (2026-07-10):
  the Entra→account group sync named in this ADR's follow-ups is implemented via AIM and
  owned by each environment root, not shared-services; the metastore follow-up stands.
- **Date:** 2026-06-30
- **Deciders:** Platform (learning build)

## Context

The dev environment cannot stand alone. It force-tunnels `0.0.0.0/0` to a hub
Azure Firewall, resolves its private endpoints through hub Private DNS zones, and
peers to a hub VNet. All of those live in the `shared-services` (hub) deployment
boundary, which was empty. We needed dev to actually plan/deploy, and we needed a
mechanism for dev to reference hub resources without violating the architecture
doc's cross-state rules (no `terraform_remote_state`, no hardcoded resource IDs).

## Decision

1. Build a **minimal `shared-services` root** now: hub VNet + `AzureFirewallSubnet`,
   Azure Firewall + policy + egress allowlist, NAT Gateway, and the four Private
   DNS zones (`blob`, `dfs`, `vaultcore`, `azuredatabricks`).
2. Dev resolves every hub dependency **by name** using Azure **data sources**
   (`azurerm_virtual_network`, `azurerm_firewall`, `azurerm_private_dns_zone`).
   The names are supplied via dev variables that default to the on-convention hub
   names.
3. Resources that touch both boundaries but are owned by the spoke — VNet peering
   (both halves) and the Private DNS zone→spoke VNet links — are created in the
   **dev root**, since dev owns its VNet.

## Consequences

- **Positive:** dev is deployable end to end; the cross-state contract is honored
  (Azure is the source of truth; a missing hub dependency fails loudly at plan);
  no state-file coupling between boundaries.
- **Trade-offs:** deploy ordering is now load-bearing — `shared-services` must be
  applied before dev, or dev's data sources 404. The hub names are a contract:
  renaming a hub resource breaks every spoke that looks it up.
- **Follow-ups:** staging/prod repeat the same pattern; the UC account-level metastore
  still belongs in `shared-services` (future pass). ~~Entra→account group sync~~ —
  done differently: AIM + env-owned groups (ADR-0008).

## References

- `docs/architecture/azure-platform-architecture.md` §1 (cross-state dependencies)
- `.claude/skills/azure-databricks-author-review/references/terraform.md` §5
