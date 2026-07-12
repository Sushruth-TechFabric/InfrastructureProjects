# ADR-0010: Remove workspace front-end IP access lists (Entra ID-only gating)

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** Platform owner

## Context

Since the pass-2 workspace controls (ADR-0002 follow-up), both workspace roots gated
the internet-reachable front-end with a workspace IP access list on top of Entra ID:
`databricks_workspace_conf` (`enableIpAccessLists = true`) + a
`databricks_ip_access_list` ALLOW list fed by `var.allowed_ip_addresses`
(`environments/dev/workspace-config.tf`, `environments/dev-lab/workspace.tf`).

In practice the list carried real operational cost for little security delta here:

- **Lockout risk was structural.** The Terraform provider talks to the same front-end
  it restricts — applying from an IP not on the list locks out both the operator and
  Terraform itself (the dev-lab runbook even documented a destroy-and-rebuild escape
  hatch). Residential/VPN egress IPs rotate, retriggering this regularly.
- **Identity is already the perimeter** for the front-end by design (the "Front-end
  access" decision in the architecture doc): Entra ID authentication, with Conditional
  Access (MFA, device/compliance) available at the tenant level. The IP list narrowed
  *where* a valid credential could be used, not *whether* one was required.
- The compute, data, and secret planes are unaffected by the list either way — they
  are sealed by SCC, back-end Private Link, and private-only storage/Key Vault (dev),
  or default-deny firewalls (dev-lab).

## Decision

Remove the workspace IP access list from **both** workspace roots (`dev`, `dev-lab`):
drop the `databricks_workspace_conf` and `databricks_ip_access_list` resources. The
front-end is gated by **Entra ID alone** (plus tenant-level Conditional Access where
configured).

- In `environments/dev`, `var.allowed_ip_addresses` had no other consumer and is
  removed entirely.
- In `environments/dev-lab`, `var.allowed_ip_addresses` **remains** — it still feeds
  the storage/Key Vault firewall allowlists, which are unchanged.

This partially supersedes ADR-0006 (its "keep every free security control" list
included the workspace IP access list) and amends the front-end hardening list in the
architecture doc.

## Consequences

- **Positive:** no more front-end/Terraform lockout class of failures; no egress-IP
  churn maintenance; CI and collaborators need no allowlist changes to reach the
  workspace or REST API.
- **Negative / trade-offs:** a stolen-but-valid credential can now be used from any
  IP — the front-end is protected by identity controls alone. Mitigate at the tenant
  level with Entra ID Conditional Access (MFA, device/compliance, trusted locations);
  in prod-like client environments, reinstating IP access lists (or Conditional Access
  location policies) should be re-evaluated per client requirements.
- **Follow-ups:** on the next `terraform apply`, Terraform deletes the ALLOW list and
  the workspace conf (resetting `enableIpAccessLists`); verify the workspace is
  reachable afterwards. Confirm Conditional Access on the Databricks enterprise app
  remains the compensating control.

## References

- Architecture doc — "Front-end access" decision and hardening list
  (`../azure-platform-architecture.md`)
- ADR-0002 (pass 2 introduced the list), ADR-0006 (lab keep-list, partially superseded)
- Workspace IP access lists:
  <https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/ip-access-list>
