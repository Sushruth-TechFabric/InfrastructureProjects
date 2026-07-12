# ADR-0007: NAT Gateway + NSG egress for dev; Azure Firewall optional

- **Status:** Accepted
- **Date:** 2026-07-07
- **Deciders:** Platform (learning build)
- **Supersedes / amends:** parts of [ADR-0001](0001-minimal-shared-services-and-cross-state-data-sources.md)
  (hub firewall + dev peering); makes [ADR-0004](0004-nat-gateway-on-firewall-subnet-non-zonal.md) dormant

## Context

The secure `dev` environment idled at **~$985–1,000/month**, ~93% of which was the hub
Azure Firewall chain (Firewall Standard ~$912/mo + hub NAT Gateway + public IPs). The
firewall's only job in this architecture is **egress control for the Databricks cluster
subnets** — and our egress policy was already pure L3/L4 **service-tag** rules
(`AzureDatabricks`, `AzureActiveDirectory`, `Storage.<region>`, `EventHub.<region>`),
not FQDN filtering. Separately, Azure retired default outbound internet access for new
subnets (Sept 2025), so SCC clusters need an **explicit** egress path no matter what.
An NSG can express the same service-tag allowlist for free; a NAT Gateway provides the
explicit egress path and a stable public IP for ~$33/mo.

Decision owner's call: drop the firewall for dev **now**; revisit whether Azure Firewall
is actually needed later.

## Decision

1. **`modules/networking` gains two mutually exclusive egress modes** (validated to
   exactly one):
   - **Firewall mode** (existing): `firewall_private_ip` set → forced-tunneling route
     table (`0.0.0.0/0` → hub firewall) on both delegated subnets. Unchanged behavior.
   - **NAT mode** (new, `enable_nat_gateway_egress = true`): a spoke-owned NAT Gateway +
     Standard public IP associated to **both** delegated subnets, plus NSG **outbound
     rules** on both delegated-subnet NSGs: allow `AzureDatabricks` (443, 3306,
     8443–8451), `AzureActiveDirectory` (443), `Storage.<region>` (443), `Sql.<region>`
     (3306, legacy Hive metastore), `EventHub.<region>` (9093), then
     `DenyAllInternetOutbound` at priority 4096 to override the default
     `AllowInternetOutBound`. Rules are **standalone `azurerm_network_security_rule`
     resources** — inline blocks would make Terraform authoritative over the NSG and
     delete the rules Databricks' network intent policy manages.
2. **`environments/dev` switches to NAT mode.** The `azurerm_firewall` and hub
   `azurerm_virtual_network` data sources, the `hub_vnet_name`/`hub_firewall_name`
   variables, and **both VNet peering halves are removed** — peering existed solely so
   the UDR could reach the firewall; Private DNS zone links do not require peering.
   Dev's only remaining hub dependency is the four Private DNS zones.
3. **`shared-services` gates the firewall chain behind `deploy_firewall` (default
   `false`):** firewall, policy, egress rule collection, firewall public IP, hub NAT
   Gateway + public IP + associations. The hub RG, hub VNet, `AzureFirewallSubnet`, and
   the four Private DNS zones remain unconditional. Firewall-related outputs are null
   when disabled.
4. **Everything else is untouched:** SCC (`no_public_ip`), back-end Private Link, all
   four private endpoints + DNS zone links, storage/Key Vault public access off,
   secretless Access Connector UAMI + narrow RBAC, cluster policies, IP access lists.

## Consequences

- **Positive:** dev idle cost drops from ~$985–1,000/mo to **~$70/mo** (4 private
  endpoints ~$29, NAT Gateway ~$33 + data, public IP ~$4, DNS zones ~$2, storage/KV
  ~$1–3). Dev can now be left running between sessions instead of mandatory same-day
  teardown. Explicit egress path also satisfies the default-outbound-access retirement.
- **Negative / trade-offs:**
  - **No FQDN-level egress control or inspection.** A service tag admits the *whole
    regional service* — e.g. `Storage.westus3` allows any storage account in the region,
    so a compromised cluster could exfiltrate to attacker-owned storage. This is the
    concrete capability Firewall Standard bought. Acceptable for dev practice data;
    **NOT the client/prod posture** — prod returns to forced tunneling + firewall.
  - The egress allowlist now lives in **two possible places** (NSG rules in the module
    for NAT mode; firewall policy in shared-services for firewall mode). Keep them in
    sync when Databricks endpoint requirements change.
  - [ADR-0004](0004-nat-gateway-on-firewall-subnet-non-zonal.md) (NAT on the firewall
    subnet, non-zonal firewall) is **dormant** — it applies only when
    `deploy_firewall = true`.
  - The hub VNet currently has no consumers (kept: free, and it preserves the hub-spoke
    reference and the peering pattern for the firewall mode's return).
- **Reverting** (if the firewall turns out to be needed): set `deploy_firewall = true`
  in shared-services, switch the dev module call back to `firewall_private_ip`, restore
  the two peering halves and the hub data sources (see git history / this ADR's diff).

## References

- Design rationale and cost model: `docs/runbooks/deploy-dev.md` (updated),
  `docs/architecture/azure-platform-architecture.md` §3 (egress modes)
- MS Learn — Default outbound access retirement; NAT Gateway integration;
  Azure Databricks VNet injection required NSG rules / egress requirements
- [ADR-0001](0001-minimal-shared-services-and-cross-state-data-sources.md),
  [ADR-0004](0004-nat-gateway-on-firewall-subnet-non-zonal.md),
  [ADR-0006](0006-cost-optimized-lab-profile.md) (the same cost pressure, for the lab)
