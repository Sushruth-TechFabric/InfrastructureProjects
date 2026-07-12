# ADR-0012: Serverless private connectivity (NCC) owned by the environment root

- **Status:** Accepted (amended 2026-07-12 — see Amendment below)
- **Date:** 2026-07-10
- **Deciders:** Platform (Sushruth)

> **Erratum (2026-07-12):** Decision point 3 and the code comment it mirrored
> stated "dev uses Databricks-backed secret scopes, not KV-backed." That is
> **false** — dev's secret scope IS Key Vault-backed (`workspace-config.tf`,
> `keyvault_metadata`). The accurate reason the `vault` NCC rule is unused today
> is that the KV-backed scope is read by the Databricks **control plane**, not
> the serverless plane; the rule remains included for future serverless
> model-serving secret access. ADRs are immutable, so the original text stands
> above with this correction noted here (see finding D9). The "the `vault` rule
> can be dropped" follow-up should be read in that light: dropping it severs the
> private path future serverless secret access will need.

## Context

The platform now needs **serverless** Databricks features (serverless SQL, model
serving, vector search, Lakebase). Serverless compute runs in a
**Databricks-managed plane**, not in our VNet-injected spoke, so the spoke NSGs,
NAT egress, and the back-end Private Link (`pep-dbw-backend-*`,
`databricks_ui_api`) do **not** cover it. Dev's ADLS (`stdbxdevwus3001`) and Key
Vault (`kv-dbx-dev-wus3-001`) have `public_network_access_enabled = false` /
`network_default_action = "Deny"` (golden rule, AGENTS.md §6), reachable only via
spoke private endpoints. Result: **serverless compute has no network path to dev
data at all** — already documented as a known gap in `sql-warehouse.tf`, which is
why its warehouse is classic (`enable_serverless_compute = false`).

Databricks' mechanism for this is a **Network Connectivity Config (NCC)** — an
account-level object whose **private endpoint rules** make Databricks stand up
managed private endpoints from the serverless plane to a target Azure resource
(`group_id` = `blob`/`dfs` for ADLS Gen2, `vault` for Key Vault). Because those
endpoints originate in a Databricks-managed subscription, the resulting private
endpoint connection lands **Pending** on our resource and the resource owner must
**approve** it.

Two forces shaped the decision: (1) which state boundary owns an account-scoped
object whose rules reference env-owned data; (2) how to approve an inbound
connection Terraform's `azurerm` provider has no resource for.

## Decision

1. **The NCC, its private endpoint rules, and the NCC→workspace binding live in
   the environment root** (`environments/dev/network-connectivity.tf`), using the
   `databricks.account` provider already declared in `providers.tf` (ADR-0008 /
   ADR-0011). *Not* shared-services. Unlike the UC metastore — one per region, a
   forced singleton, hence shared-services (ADR-0011) — an account may hold
   **many** NCCs, and these rules embed **dev-owned resource ids**. Keeping them
   in the env root keeps dev's data path inside dev's state boundary (the
   ADR-0011 principle). The binding is workspace-specific, the same shape ADR-0008
   used to keep `databricks_mws_permission_assignment` in the env root. One NCC
   per environment; staging/prod get their own copy of the file.

2. **No public access is widened.** The NCC path is *additive private
   connectivity*; storage and Key Vault stay `Deny`/private. Both modules default
   to `public_network_access_enabled = false` and this root passes no override.

3. **Both storage (blob + dfs) and Key Vault (vault) rules are built now.** ADLS
   is the runtime dependency for all four serverless use cases. Key Vault is *not*
   reached by serverless today (dev uses Databricks-backed secret scopes, not
   KV-backed), but the `vault` rule is included for future model-serving secret
   access — a private path either way.

4. **Owner-side approval is automated with the `azapi` provider.** `azurerm` has
   no resource to approve a third-party-initiated connection. `azapi` lists the
   `privateEndpointConnections` sub-resources and PATCHes the `Pending` ones to
   `Approved`. Consequence: a **two-phase apply** — the list data sources read
   current Azure state at plan time (no `depends_on`, so their `for_each` keys stay
   known), so apply #1 creates the rules (connections go Pending) and apply #2
   sees and approves them. This mirrors the repo's existing two-phase workspace
   apply and metastore import-or-create runbook steps.

## Consequences

- **Positive:** serverless features get a private path to dev data with zero
  public exposure; account-scoped networking stays inside the env boundary
  (blast radius, promotion story) using the existing account provider; approval
  is codified, not a manual click.
- **Negative / trade-offs:** adds the `azapi` provider (fourth in dev) and a
  two-phase apply for the approval; the connection-name match is by "Pending
  status" rather than a stable identifier (safe here because same-owner spoke PEs
  are pre-approved, never Pending). DNS for the serverless-side endpoints is
  handled inside the Databricks-managed plane, so our spoke Private DNS zones are
  untouched — nothing to verify there, but also nothing we control.
- **Follow-ups:** flipping `enable_serverless_compute = true` on the dev SQL
  warehouse (or adopting any serverless feature) is a separate behavior/cost
  decision, intentionally out of this pass. If the `vault` rule proves unused it
  can be dropped without touching KV's posture. Once CI/CD (OIDC) lands, confirm
  the automated approval works unattended; consider validating whether the
  connection name equals the rule's exported `endpoint_name` in this tenant — if
  so, the list/filter collapses to a direct reference and a single-phase apply.

## References

- ADR-0011 (account metastore in shared-services — the singleton contrast)
- ADR-0008 (workspace-specific account objects owned by the env root)
- ADR-0006 (dev-lab uses serverless over *public* storage — the other end of this
  trade-off)
- `environments/dev/network-connectivity.tf`; deploy-dev runbook "serverless
  private connectivity" step
- Databricks: `databricks_mws_network_connectivity_config`,
  `databricks_mws_ncc_private_endpoint_rule`, `databricks_mws_ncc_binding`

## Amendment (2026-07-12)

The 2026-07 platform review (findings T1, T2) surfaced two defects in the
`azapi` approval implementation this ADR described. The original decision stands;
the mechanism is corrected as follows.

1. **Approval is now filtered to THIS NCC's own endpoints, not "any Pending"
   (T2, security).** Decision point 4 and the original code approved every
   connection whose `privateLinkServiceConnectionState.status == "Pending"`,
   reasoning only that same-owner spoke private endpoints are pre-approved and so
   never Pending. That reasoning did not consider an **adversarial or accidental**
   Pending connection: any third party who raises a manual private endpoint
   against the storage-account or vault resource id lands `Pending` and was
   silently Approved on the next apply — a private network path into the sealed
   data plane. The approval now matches connection names against this NCC's own
   `databricks_mws_ncc_private_endpoint_rule.this[*].endpoint_name` (the rule
   exports `endpoint_name`, which equals the connection name Databricks raises on
   the target). Connections outside that allowlist are never approved. This is
   the "connection name equals the rule's exported `endpoint_name`" validation the
   original Follow-ups anticipated — now relied upon, and flagged for one-time
   runtime confirmation in this tenant.

2. **The approval machinery is gated behind `ncc_approval_enabled` (bool, default
   false) — an explicit two-phase apply (T1, greenfield).** The original text
   asserted the list data sources' `for_each` keys "stay known" because the reads
   have no `depends_on`. That holds only once storage/KV already exist in state.
   On a **greenfield** apply (e.g. staging's first plan), `parent_id =
   module.storage.storage_account_id` / `module.key_vault.key_vault_id` are
   unknown at plan → the data reads defer → `local.*_pending` is unknown →
   `for_each` on the approvals fails with "Invalid for_each argument … cannot be
   determined until apply." Gating the azapi list data sources **and** the
   `azapi_update_resource` approvals behind `ncc_approval_enabled` removes them
   from the graph on apply #1 (infra pass) and re-introduces them on apply #2
   (flip the flag in `terraform.tfvars`), consistent with the repo's existing
   two-phase-apply doctrine. This preserves the promotion contract ("promotion is
   a tfvars change").

3. **`for_each` is re-keyed on the stable rule set, removing plan churn.**
   Keying the approvals on transient `Pending` status meant an entry dropped out
   of the map once approved and planned as a **destroy** on the next run (a
   non-empty plan on unchanged code, defeating drift detection). The approvals
   are now keyed by the stable rule name (`blob`/`dfs`/`vault`); an
   already-Approved connection stays in the map as an idempotent no-op PATCH.

See `environments/dev/network-connectivity.tf` (mirrored byte-identically into
`environments/staging/`).
