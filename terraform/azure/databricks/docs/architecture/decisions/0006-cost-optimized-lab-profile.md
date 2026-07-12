# ADR-0006: Cost-optimized `dev-lab` profile

- **Status:** Accepted (2026-07-02 — `environments/dev-lab/` built per the design doc; the workspace IP access list clause is superseded by ADR-0010)
- **Date:** 2026-07-01
- **Deciders:** Platform (learning build)

## Context

The platform owner has **$150/month** Azure credits and needs an **always-available**
Databricks workspace for daily data-engineering + Gen AI practice. The secure enterprise
stack idles at ~$730+/month (firewall + NAT + private endpoints) and an always-running
cluster adds ~$450+/month — neither is affordable. "Always on" was clarified to mean
always **available**, with strictly on-demand compute.

## Decision

1. **Separate root** `environments/dev-lab/` (own state key), designed in full in
   [`docs/design/dev-lab-profile.md`](../../design/dev-lab-profile.md) — **documentation
   now, implementation later**. The secure build remains the primary learning track.
2. **Omit** the hub (firewall/NAT/DNS), VNet injection, and all private endpoints.
   **Keep** every free security control: SCC (`no_public_ip`), secretless Access
   Connector UAMI + narrow RBAC, workspace IP access list, storage/KV default-deny.
3. **Module changes are backward-compatible only:** add `public_network_access_enabled`
   (default `false`) and `network_default_action` (default `"Deny"`) to `modules/storage`
   and `modules/key-vault`; secure roots pass nothing and stay byte-identical. No forks,
   no profile flags inside modules.
4. **Compute:** serverless SQL (2X-Small, auto-stop 10 min) + one single-node
   auto-terminating cluster under a policy that forbids disabling auto-termination;
   Gen AI via pay-per-token Foundation Model APIs. No always-on compute, no GPU cluster.
5. **Unity Catalog via the account's auto-enabled metastore** (no `databricks_metastore`
   in Terraform); workspace-level chain only (storage credential → external locations →
   `lab` catalog → grants). Grants go to the deploying **user** — a documented solo-lab
   exception to the groups-only rule, to be reverted when group sync exists.
6. **Budget control in code:** `azurerm_consumption_budget_subscription` at $150 with
   50/80/100% notifications.
7. **Secure stack is practiced in ephemeral sessions** (apply → verify → destroy same
   day, ≈ $4–6/session); it is never left running on this subscription.

## Consequences

- **Positive:** practice fits the budget (~$3–5 idle + ~$50–105 with compute); daily UC +
  Gen AI work is possible; the secure reference stays intact and still deployable.
- **Negative / trade-offs:** the lab's data plane traverses public endpoints
  (default-deny + allowlist, identity-gated) — explicitly NOT the client posture;
  per-user grants violate the groups rule until identity sync exists.
- **Follow-ups:** ~~build the lab per the design doc; flip this ADR to Accepted~~ (done
  2026-07-02 — see `environments/dev-lab/README.md` for per-person setup); move grants
  to groups once Entra sync lands; revisit ADR-0002's remaining gaps for the secure env
  (done separately).

## References

- Design doc: [`docs/design/dev-lab-profile.md`](../../design/dev-lab-profile.md)
- [ADR-0002](0002-infra-layer-first-defer-databricks-provider.md) (layering),
  [ADR-0003](0003-module-vs-root-boundary.md) (module rules)
