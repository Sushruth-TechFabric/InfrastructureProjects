# Design: `dev-lab` — Cost-Optimized Databricks Practice Environment

> **Status: IMPLEMENTED (2026-07-02)** in `environments/dev-lab/` — per-person setup
> steps live in [`environments/dev-lab/README.md`](../../environments/dev-lab/README.md).
> This document remains the build spec / rationale. Companion decision record:
> [ADR-0006](../architecture/decisions/0006-cost-optimized-lab-profile.md) (Accepted).
> Implementation deltas from §5: a 4th `catalog` filesystem + external location was
> added because auto-provisioned metastores have no root storage (the `lab` catalog
> needs its own `storage_root`), and the storage module additionally gained
> `network_ip_rules` + `network_resource_access_ids` so Databricks compute reaches the
> default-deny lake via an Access Connector resource-instance rule (identity, not IP).
>
> The **secure enterprise** build (`shared-services` + `environments/dev`) remains the
> primary learning track and the architectural reference. This lab is a deliberate,
> documented downgrade for daily practice on a personal budget.
>
> **Update (2026-07-07, [ADR-0007](../architecture/decisions/0007-nat-gateway-nsg-egress-for-dev.md)):**
> the secure `dev` root now defaults to **NAT Gateway + NSG egress** (no Azure Firewall)
> and idles at ~$70/month. The "~$730+/mo" comparisons and the "$4–6 ephemeral session"
> playbook below describe the pre-ADR-0007 **firewall posture**, which still exists
> behind `deploy_firewall = true` in shared-services.

---

## 1. Problem and goal

- **Budget:** $150/month Azure credits, total, for everything.
- **Need:** practice **data engineering** (Delta, pipelines, SQL, Unity Catalog) and
  **Gen AI** (Foundation Model APIs, RAG patterns) on a workspace that is
  **always available** — log in any time, no redeploy ceremony.
- **Reality check:** the secure enterprise stack idles at **~$730+/month** (Azure Firewall
  ~$650–900 alone, plus NAT Gateway + 4 private endpoints), and one always-running small
  cluster is another ~$450+/month. Neither fits.

**Reframe that makes $150 work:** the *workspace* is always available (the workspace
resource costs $0 when no compute runs); *compute* is strictly on-demand — serverless
that auto-stops and clusters that auto-terminate. "Always on" applies to availability,
never to compute.

## 2. Cost model (West US 3, rough)

| Item | Monthly estimate |
| --- | --- |
| Databricks workspace (premium, idle) | $0 |
| ADLS Gen2 (few GB practice data) | ~$1–3 |
| Key Vault | ~$0–1 |
| Access Connector + UAMI | $0 |
| Budget alert resource | $0 |
| **Idle total** | **~$3–5** |
| Serverless SQL 2X-Small, ~1–2 hr/day | ~$25–50 |
| Single-node DS3_v2 cluster, ~1–2 hr/day | ~$25–40 |
| Foundation Model APIs (practice volume) | ~$1–10 |
| **Practice total** | **~$55–105** |

Omitted vs the secure build (the ~$730/mo delta): Azure Firewall + policy, NAT Gateway,
hub VNet + peering, VNet injection, all 4 private endpoints + private DNS.

## 3. Shape

A **separate root** `environments/dev-lab/` with its own state key
(`environments/dev-lab/terraform.tfstate`). Not a toggle inside the secure root — the two
differ too much structurally (no networking module at all), and a separate root keeps the
secure config pristine as the reference implementation.

| Aspect | dev-lab | secure dev (reference) |
| --- | --- | --- |
| Hub / firewall / NAT | ✗ not deployed | ✓ |
| VNet injection + forced tunneling | ✗ (managed VNet) | ✓ |
| Private endpoints + private DNS | ✗ | ✓ |
| SCC (`no_public_ip`) | ✓ **kept — free** | ✓ |
| Front-end | public, Entra ID-gated (ADR-0010) | public, Entra ID-gated (ADR-0010) |
| Workspace SKU | premium (UC, serverless) | premium |
| Secretless data access (Access Connector UAMI) | ✓ **kept** | ✓ |
| Storage/KV public network access | **enabled** (default-deny + allowlist) | disabled |
| Unity Catalog | ✓ via auto-enabled metastore | later (shared-services pass) |
| Budget alert | ✓ $150 (50/80/100%) | n/a |

Reused modules, unchanged: `identity`. Reused with backward-compatible additions:
`storage`, `key-vault` (see §4). Not used: `networking`, `databricks-workspace`
(workspace is written inline in the lab root because it omits all VNet parameters —
simpler than making the module's VNet inputs optional).

## 4. Module-change strategy (how to touch shared modules safely)

**Rule: backward-compatible variables with secure defaults.** Never fork a module, never
put a "profile" flag inside one, never change an existing default.

Concretely, add to `modules/storage` and `modules/key-vault`:

```hcl
variable "public_network_access_enabled" {
  type        = bool
  description = "Expose a public endpoint. Keep false (private-endpoint-only) outside lab profiles."
  default     = false # secure default — existing roots unaffected
}

variable "network_default_action" {
  type        = string
  description = "Firewall default action when public access is enabled."
  default     = "Deny"
}
```

…and wire them into the existing hardcoded spots. The secure roots pass nothing, so their
plans stay **byte-identical** (verify with `terraform plan` showing no changes). Only the
lab root overrides `public_network_access_enabled = true` — and even then keeps
`default_action = "Deny"` plus an IP allowlist, so "public" means *reachable through a
firewall*, not *open*.

## 5. Lab root contents (build list)

- `providers.tf` — `azurerm ~> 4.0` **and** `databricks ~> 1.121` (workspace-scoped, auth
  via `azure_workspace_resource_id` → uses `az login`; no PATs). TF `>= 1.9, < 2.0`.
- `backend.tf` — azurerm backend, key `environments/dev-lab/terraform.tfstate` (own state;
  can share the dev bootstrap storage account).
- `variables.tf` / `terraform.tfvars` — subscription_id; `westus3`/`wus3`;
  `storage_account_name` (e.g. `stdbxlabwus3001`); tags (`Environment = "lab"`);
  `allowed_ip_addresses` (list; your home/VPN egress IPs — storage/KV firewalls
  only, not the workspace front-end); `cluster_node_type`
  (`Standard_DS3_v2`); `autotermination_minutes` (20); `enable_serverless` (true);
  `warehouse_auto_stop_mins` (10); `budget_amount` (150); `budget_contact_emails`.
- `main.tf` —
  - RGs: `rg-databricks-dbx-lab-wus3-001`, `rg-storage-dbx-lab-wus3-001`, `rg-security-dbx-lab-wus3-001`.
  - `module "storage"` (public access **true**, default-deny, IP rules), filesystems
    `["bronze", "silver", "gold"]`; `module "key_vault"` (same override); `module "identity"`.
  - Inline `azurerm_databricks_workspace`: `sku = "premium"`,
    `public_network_access_enabled = true`, `custom_parameters { no_public_ip = true }`,
    **no VNet fields**, named managed RG.
  - `azurerm_role_assignment`: UAMI → `Storage Blob Data Contributor` on the lab ADLS.
  - `azurerm_consumption_budget_subscription`: `budget_amount`, notifications at 50/80/100%
    (100% forecasted too) → `budget_contact_emails`.
- `workspace.tf` (databricks provider) —
  - `databricks_cluster_policy` "lab-personal": single node, `node_type_id` allowlist
    (small only), `autotermination_minutes` **fixed** (cannot be disabled), latest LTS
    runtime, `data_security_mode = SINGLE_USER` (UC-enabled).
  - One `databricks_cluster` under that policy (practice cluster; it costs nothing while
    terminated).
  - `databricks_sql_endpoint`: serverless, size 2X-Small, `auto_stop_mins =
    var.warehouse_auto_stop_mins` (when `enable_serverless`).
  - `databricks_secret_scope` (Databricks-backed) for practice secrets.
- `uc.tf` (Unity Catalog) —
  - `databricks_storage_credential` with `azure_managed_identity { access_connector_id }`
    (+ `managed_identity_id` for the UAMI). `depends_on` the role assignment
    (RBAC propagation; a 403 on first apply resolves by re-applying).
  - `databricks_external_location` × bronze/silver/gold:
    `abfss://<fs>@<account>.dfs.core.windows.net/`.
  - `databricks_catalog` `lab` + `databricks_schema` `raw`, `curated`.
  - `databricks_grants` to `data.databricks_current_user` — **solo-lab exception** to the
    "groups not individuals" rule (no group sync exists yet); revisit when identity
    federation is set up.
  - **No `databricks_metastore` resource.** New Databricks accounts are auto-enabled for
    UC: a regional default metastore auto-attaches to new workspaces. Preflight: after
    workspace creation open Catalog in the UI (or `databricks metastores list`); if — and
    only if — no metastore exists for westus3 (old account), attach one once via
    accounts.azuredatabricks.net (account admin), then re-apply. Kept out of Terraform to
    avoid the account-level provider auth path.
- `outputs.tf` — workspace_url, warehouse id, storage name, catalog name.

### Known caveats (write them into the root's header comment when building)

1. **Two-phase apply:** databricks-provider resources need the workspace live and your IP
   allowed. If a single `apply` races, run
   `terraform apply -target=azurerm_databricks_workspace.this` first, then full apply.
2. **Serverless** requires account-level enablement (default on new accounts); if
   unavailable, set `enable_serverless = false` (classic warehouse with auto-stop).
3. **Storage credential RBAC lag:** role assignment can take minutes to propagate;
   re-apply is safe.
4. Storage/KV public-but-default-deny is the documented lab trade-off; identity + RBAC
   still gate all data access. The secure profile remains the reference posture.

## 6. Cost-management playbook (both profiles)

**Lab (once built):**
- Everything that can auto-stop, auto-stops (warehouse 10 min, cluster 20 min). Never
  disable auto-termination — the cluster policy forbids it.
- Gen AI: use **Foundation Model APIs** (pay-per-token, no idle cost) and serverless
  model serving that scales to zero — never a dedicated GPU cluster.
- Budget alert emails at $75 / $120 / $150; at 80% stop scheduling new work.
- Check spend: Azure portal → Cost Management → Cost analysis, filter tag
  `Project = azure-databricks-platform`.
- Leaving for >1 week? `terraform destroy` the lab; state + code + this doc rebuild it in
  minutes. Data in ADLS survives only if you destroy selectively — export anything
  precious first (or `terraform state rm` the storage before destroy).

**Secure enterprise (practice in ephemeral sessions):**
- The firewall bills ~ $1.25/hr + NAT + PEs ⇒ a 3–4 hour hands-on session ≈ **$4–6**.
- Session loop: `apply` shared-services → `apply` dev → practice/verify → **`destroy` dev
  → `destroy` shared-services the same day**. Never leave it running overnight.
- What survives destroy: remote state, all code, all docs — i.e. everything that matters.
  What doesn't: any data written into the session's ADLS (fine for infra practice).
- Budget the sessions: ~2 sessions/week ≈ $40–50/mo — fits alongside the lab.

## 7. Deferred beyond this design

Same list as the platform's client-deferral note (observability, AZ/DR, state-backend
hardening) **plus**: front-end Conditional Access policy, CMK, and moving lab UC grants
from the individual user to synced Entra groups.
