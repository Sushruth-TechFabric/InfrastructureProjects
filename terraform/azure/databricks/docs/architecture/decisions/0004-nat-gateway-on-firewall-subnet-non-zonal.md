# ADR-0004: NAT Gateway on the firewall subnet (non-zonal firewall)

- **Status:** Accepted — **dormant since
  [ADR-0007](0007-nat-gateway-nsg-egress-for-dev.md)** (2026-07-07): the firewall chain
  this decision configures is deployed only when `shared-services` sets
  `deploy_firewall = true`. The decision below still governs that (optional) path.
- **Date:** 2026-06-30
- **Deciders:** Platform (learning build)

## Context

The hub needs a stable, auditable outbound public IP for all spoke egress (which
is force-tunneled through the Azure Firewall). Azure Firewall SNATs through its own
public IPs (2,496 SNAT ports per IP), which can exhaust under load. Azure NAT
Gateway provides 64,512 SNAT ports per IP and a stable egress address.

There is a known sharp edge here: **how** NAT Gateway integrates with Azure
Firewall, and whether it can attach to `AzureFirewallSubnet` at all.

## Decision

Follow the Microsoft-documented Firewall + NAT Gateway integration: associate the
NAT Gateway **directly to the `AzureFirewallSubnet`**
(`azurerm_subnet_nat_gateway_association`). The firewall then egresses through the
NAT Gateway's public IP.

This carries a **hard constraint**: the integration is supported **only for a
non-zonal firewall** — NAT Gateway (a zonal/regional resource) cannot back a
zone-redundant Azure Firewall. Therefore the `azurerm_firewall` has **no `zones`
argument**, and the public IPs are likewise not zone-pinned.

## Consequences

- **Positive:** scalable, stable, auditable egress IP; matches the reference
  architecture and the platform diagrams (`fw → nat → approved internet`).
- **Negative / trade-off:** the firewall is a **single-AZ SPOF**. This is
  explicitly consistent with the architecture doc's resilience deferral ("single
  availability zone for now… NAT Gateway is a zonal SPOF as drawn"). It **must be
  revisited before a production/client deployment** (zone-redundant firewall would
  require dropping NAT Gateway integration or using a different egress design).

## References

- MS Learn — Integrate NAT Gateway with Azure Firewall in a hub-spoke network
  (tutorial, updated 2026-03):
  <https://learn.microsoft.com/en-us/azure/nat-gateway/tutorial-hub-spoke-nat-firewall>
- `docs/architecture/azure-platform-architecture.md` §0 (resilience deferral), §3
