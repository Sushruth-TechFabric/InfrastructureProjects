# Platform review — Terraform (dev/staging) and documentation

- **Date:** 2026-07-11
- **Scope:** `environments/dev/`, `environments/staging/`, `shared-services/`, all of `modules/`, and the full `docs/` + agent-docs/skills surface. `environments/dev-lab/` and `environments/prod/` reviewed only as context (dev-lab is a documented ADR-0006 exception; prod is a 0-byte stub).
- **Method:** seven independent review passes (correctness, security, consistency, reusability, workspace-object configurability, identity, documentation ×2), each conducted against the golden rules in `.claude/skills/azure-databricks-author-review/SKILL.md` and cross-checked against ADRs 0001–0013 before flagging. All blockers and top should-fixes were re-verified line-by-line in a final pass. Deliberate documented postures (ADR-0004 non-zonal NAT, ADR-0006 lab profile, ADR-0007 NAT+NSG dev egress, ADR-0010 internet-reachable front end, ADR-0012 NCC placement, ADR-0013 Lakebase) were **not** reported as defects; where code contradicts its own ADR, that is reported.
- **Severity:** `blocker` — breaks a deploy or creates a security hole; `should-fix` — real defect or debt with a nameable consequence; `nice-to-have` — polish/hygiene.
- **Finding IDs** are `T-*` (Terraform), `R-*` (reusability), `W-*` (workspace objects), `I-*` (identity), `D-*` (docs). Findings that surfaced in multiple passes are stated once and cross-referenced.

**Headline:** the platform is in unusually good shape — modules are genuinely value-free, cross-state lookups are name-derived per ADR-0001, RBAC is group-only with zero `Owner`/`Contributor` grants, no secrets exist in tracked files, and dev→staging is a proven byte-identical copy. The two blockers are both in `network-connectivity.tf` (one greenfield plan failure, one security gap already tracked as debt but now duplicated into staging), and the dominant structural theme is that the ~1,300-line workspace-objects layer reuses by **verbatim file copy**, which is exactly what the new-client goal will break first.

---

## 1. Terraform review — dev and staging

### 1.1 Blockers

**T1 — blocker — Greenfield apply of any environment fails at plan: unknown `for_each` on the NCC approval resources.**
`environments/dev/network-connectivity.tf:93-120` (byte-identical in staging). The azapi list data sources use `parent_id = module.storage.storage_account_id` / `module.key_vault.key_vault_id`. On a first apply those IDs are unknown → the data reads are deferred → `local.storage_pending`/`vault_pending` are unknown → `for_each` on `azapi_update_resource.approve_*` errors with "Invalid for_each argument … cannot be determined until apply". The header comment (lines 87-92, "keys are always known") is only true once storage/KV already exist in state — dev never hit this because the file landed after storage existed, but **staging's first plan per the promotion notes will fail**, contradicting "promotion is a tfvars change" (`docs/design/staging-promotion-notes.md`). *Verified in this review.*
**Fix:** gate the approval pair behind `var.ncc_approval_enabled` (default `false`, flipped after the infra pass — consistent with the existing two-phase-apply doctrine), or document an explicit `terraform apply "-target=module.storage" "-target=module.key_vault"` pre-pass in the runbook and promotion notes. ADR-0012 documents the Pending→Approved two-phase, not this failure; amend it alongside the fix.

**T2 — blocker (security) — NCC approval loop auto-approves ANY pending private-endpoint connection on the data lake and Key Vault.**
`environments/dev/network-connectivity.tf:105-117` + approvals `:119-155` (byte-identical in staging). The filter is status-only: `if try(c.properties.privateLinkServiceConnectionState.status, "") == "Pending"`. Any third party who raises a manual private-endpoint connection against the storage account or vault resource ID lands `Pending` and is silently **Approved on the next apply**, handing an external VNet a private network path into the sealed data plane — made worse by `shared_access_key_enabled = true` (T5). Found independently by three review passes; already tracked as gap A2 in `staging-promotion-notes.md:73-75` ("same exposure, doubled") — acknowledged debt, still open, now copied into a second environment. ADR-0012 reasons only about same-owner spoke PEs, not adversarial pending connections. *Verified in this review.*
**Fix:** filter approvals to connections belonging to this NCC's rules — match against `databricks_mws_ncc_private_endpoint_rule.this[*].endpoint_name` (the rule exports it) instead of approving every `Pending`. Side benefit: keying `for_each` on the stable rule set instead of transient status also removes the perpetual plan churn where approved entries plan as destroys on the next run (unchanged-code/non-empty-plan defeats the repo's drift-detection doctrine).

### 1.2 Correctness — should-fix

**T3 — should-fix — Committed tfvars carry the all-zeros `databricks_account_id`; the committed dev root cannot reproduce the deployment.**
`environments/dev/terraform.tfvars:38`, `shared-services/terraform.tfvars:27` — `"00000000-0000-0000-0000-000000000000" # TODO` passes the GUID-regex validation and fails at apply with an opaque 401/404. The same file commits a real subscription GUID (line 7, still labeled `# TODO`), so the committed tfvars have drifted from deployed truth. Tracked as gap B2 in the promotion notes.
**Fix:** set the real GUID (an identifier, not a secret, per the variable's own doc), delete the stale TODOs, and strengthen the validation in all three roots to reject the all-zeros placeholder. Document the "must be identical across shared-services/dev/staging" invariant.

**T4 — should-fix — The review target largely exists only in the working tree; golden rule 5 ("commit the lock file") is unmet.**
Untracked per `git status`: **all of `modules/workspace-access/`**, ADRs 0007–0013, `staging-promotion-notes.md`, `environments/dev/{uc,catalogs,lakebase,sql-warehouse,network-connectivity,workspace-permissions}.tf`, most of `environments/staging/` (including `.terraform.lock.hcl` and `terraform.tfvars.example`), `shared-services/uc.tf`, and the `azure-databricks-lookup` skill. Additionally, staging is a **staged rename from `environments/qa/`** whose tracked `terraform.tfvars` is deleted in the worktree — commit as-is and an orphaned rename artifact lands in history. A fresh clone today gets a dev `main.tf` that references a module that doesn't exist in the repo.
**Fix:** commit the full working set as one reviewed change; `git rm --cached terraform/azure/databricks/environments/staging/terraform.tfvars` first (or restore it — see R8 for which pattern to pick).

### 1.3 Security — should-fix

**T5 — should-fix — Shared-key auth left enabled on the hardened data lake.**
`modules/storage/main.tf:35` — `shared_access_key_enabled = true # kept on for now…`. All sanctioned access is identity-based (Access Connector UAMI + UC), and Terraform manages filesystems via the ARM plane, so nothing needs account keys. Keys-on means any principal with `listKeys` bypasses both Entra RBAC and UC — and pairs badly with T2. An inline "for now" comment is not a decision record; no ADR sanctions it. Also a module-level env assumption (see R1). *Verified.*
**Fix:** expose as a module variable, default `false`; if any root genuinely needs keys, it opts in with a stated reason.

**T6 — should-fix — Workspace-managed (DBFS root) storage account has no private posture — the one storage account left publicly network-reachable.**
`modules/databricks-workspace/main.tf:25-60` sets SCC + VNet injection but no `default_storage_firewall_enabled = true` / `access_connector_id`, so the Databricks-managed storage in `rg-dbw-managed-*` (DBFS root: FileStore, libraries, init scripts, legacy hive) keeps default public network access. Golden rule 7 ("data plane fully private") currently only covers the customer ADLS + KV; no ADR acknowledges this exception.
**Fix:** enable the workspace default-storage firewall (requires the access connector to exist before the workspace — the sibling identity module is already wired in the roots), or record an ADR accepting the exposure.

**T7 — should-fix — Staging silently inherits dev's NAT+NSG egress posture with no decision covering it.**
`environments/staging/main.tf:149` — `enable_nat_gateway_egress = true` (verbatim copy). ADR-0007 explicitly scopes NAT egress as "NOT the client/prod posture"; staging is the promotion-fidelity environment yet ships with no FQDN egress control and the regional-service-tag exfiltration surface (`Storage.westus3` allows any storage account in the region). Neither ADR-0007 nor the promotion notes decides staging's egress mode.
**Fix:** an explicit ADR amendment accepting NAT egress for staging, or switch staging to firewall mode before it becomes the pre-prod reference. If firewall mode is chosen, fix T10 first.

**T8 — should-fix — Staging purges Key Vaults on destroy — dev convenience baked in code, copied verbatim.**
`environments/staging/providers.tf:49-53` — `purge_soft_delete_on_destroy = true` under a comment that says "(dev convenience). In prod you would leave this false." A staging destroy permanently purges the vault, defeating the recovery posture the key-vault module deliberately enforces (`purge_protection_enabled = true`, `modules/key-vault/main.tf:29`). Contradicts the E7 principle ("everything that differs lives in tfvars"). *Verified.*
**Fix:** drive from a variable (`kv_purge_on_destroy`, default `false`; dev's tfvars sets `true`) — provider feature blocks accept variable references, so the byte-identical-code contract survives.

**T9 — should-fix — The shared regional metastore is owned by dev's admin group — cross-environment privilege.**
`shared-services/terraform.tfvars:44` — `metastore_owner = "grp-dbx-dev-admins"`. Metastore owner = metastore admin: dev's admins can manage every catalog, credential, and external location of **every** workspace on the metastore, including staging's (`ISOLATED` bindings don't bind the metastore admin). A dev-root destroy also deletes the owning group, orphaning the shared metastore. ADR-0011 acknowledged this as interim ("swap … if/when created"), but the risk changed materially once staging landed. The hardcoded string also re-encodes the naming grammar (`project=dbx`, `env=dev`) outside any derivation — a `project` rename silently breaks it (see also I4). *Verified.*
**Fix:** create a small platform-wide admins account group (in shared-services' own state) and transfer metastore ownership to it.

**T10 — should-fix — Firewall-mode egress allowlist has drifted from the NSG allowlist ADR-0007 requires it to mirror.**
`shared-services/main.tf:186-203` vs `modules/networking/main.tf:177-203` — the firewall rule collection lacks the `Sql.<region>` tag and port `9093` (EventHub), both present in the NSG list, and `source_addresses = ["10.0.0.0/8"]` is untightened (should be `var.spoke_address_ranges`). Dormant while `deploy_firewall = false`, but flipping firewall mode on today breaks cluster log delivery and legacy Hive metastore — the exact drift ADR-0007's "keep them in sync" consequence warns about.
**Fix:** mirror the five NSG service-tag/port pairs into the firewall rules and parameterize the source ranges.

**T11 — should-fix — No workspace hardening at all: token lifetimes, notebook exfil controls, user-isolation enforcement unmanaged.**
`environments/dev/workspace-config.tf` (and staging copy) contains only three cluster policies and one secret scope — no `databricks_workspace_conf` (`maxTokenLifetimeDays`, `enableExportNotebook`, `enableResultsDownloading`, `enforceUserIsolation`), no `databricks_entitlements` stripping `allow-cluster-create` from the built-in `users` group. Consequences: PATs mintable with indefinite lifetime against an internet-reachable front end (the exact ADR-0010 threat model); if the workspace `users` group carries the default cluster-create entitlement, every cluster policy is advisory (needs runtime confirmation in the admin console); notebook export is an unmonitored exfil channel in a coarse-egress environment. Tracked as D3 in the promotion notes; `references/databricks.md` §8 calls this MUST-level.
**Fix:** add a `workspace-hardening.tf` with `databricks_workspace_conf` + `databricks_entitlements` (see also I6).

**T12 — should-fix — Cluster policies constrain only `autoscale.*`, and the runtime "pin" is cosmetic.**
`environments/dev/workspace-config.tf:57-61,72-98` — `"spark_version": {"type": "unlimited", "defaultValue": "auto:latest-lts"}` lets users pick any runtime (the comment "Pin to long-term-support runtimes" is untrue), and worker bounds exist only as `autoscale.min/max_workers`, so a fixed-size cluster (`num_workers: 40`) bypasses the caps entirely. Tracked as D1/D2 in the promotion notes. *Verified.*
**Fix:** `spark_version` → `allowlist`/`regex` (e.g. `.*-lts.*`); add a `num_workers` range or `"type": "forbidden"` (force autoscale) to all three policies.

**T13 — should-fix (needs runtime confirmation) — KV-backed secret scope reads may be blocked by the vault's own network posture.**
Scope: `environments/dev/workspace-config.tf:109-116` (KV-backed via `keyvault_metadata`); vault: `modules/key-vault/main.tf:35` (`public_network_access_enabled = false`). Classic-cluster scope reads are performed by the Databricks control plane as the first-party SP; with PNA fully disabled and no trusted-services bypass, `dbutils.secrets.get` may 403/time out — and the tempting under-pressure "fix" would be re-opening public access. The ADR-0012 NCC `vault` rule covers only the serverless plane, not this path.
**Fix:** runtime-test a scope read from a classic cluster; document the sanctioned private path (or the trusted-bypass decision) before anyone hits it in anger.

### 1.4 Correctness/security — nice-to-have

- **T14** — Five of six modules declare no `required_version`/`required_providers` (`modules/{networking,storage,key-vault,identity,databricks-workspace}` — contrast `modules/workspace-access/versions.tf`). `modules/networking/variables.tf:89-94` even uses cross-variable validation requiring TF ≥ 1.9 without declaring it. Add a `versions.tf` to each, mirroring workspace-access. (Golden rule 5; ADR-0005 covers roots only.)
- **T15** — The workspace-scoped databricks provider doesn't pin `auth_type` (`environments/dev/providers.tf:67-69`) while the account provider does, with a stated fail-fast rationale. Add `auth_type = "azure-cli"` (overridable) to match.
- **T16** — Private-endpoint subnet has no NSG (`modules/networking/main.tf:83-88`); add an inbound allowlist for defense in depth.
- **T17** — No diagnostic/audit logging anywhere in scope (no `azurerm_monitor_diagnostic_setting` for KV/storage/workspace, no NSG flow logs). ADR-0010's compensating-control story ("stolen credential usable from any IP") depends on detection that doesn't exist. Worth an ADR-level decision even if deferred.
- **T18** — Storage: no `infrastructure_encryption_enabled`/CMK option; fine for dev, expose as variables before real client data lands.
- **T19** — Staging's state addresses, file headers, and Azure-side audit descriptions all say "dev" (`databricks_sql_endpoint.dev`, `databricks_database_instance.dev`, approval `description = "…dev serverless NCC…"`, `# environments/dev — …` headers). Intentional consequence of the E7 verbatim copy, but portal audit trails on staging's storage will read "dev". Fix in dev first (env-neutral labels + `var.environment` interpolation), add `moved` blocks, re-copy. Never edit staging alone.

### 1.5 Dev vs staging consistency — verdict

Independently verified: **all 11 shared `.tf` files are byte-identical**; only `backend.tf`/`backend.hcl.example` (comments + env token) and tfvars differ; `variables.tf` declares identical sets; lock files identical (azurerm 4.80.0, databricks 1.121.0, azuread 3.9.0, azapi 2.10.0, consistent with shared-services). tfvars comparison: CIDRs `10.10.0.0/20` → `10.11.0.0/20` (documented non-overlap), all tokens correctly staging-ized, Lakebase on(dev)/off(staging) per ADR-0013 §6, identical sizing (intentional). **No accidental drift exists today.** Cross-state tracing is clean: DNS zones and metastore resolve by name to shared-services creations; no `terraform_remote_state`; the only hardcoded ID is the AzureDatabricks first-party `client_id` (`main.tf:89`), a documented global constant — correct as-is.

The residue, all classified intentional-per-E7 but with unrecorded trade-offs: T8 (purge-on-destroy), T19 (dev labels), and **R7** (dev pins `hub_resource_group_name`/`storage_account_name` in tfvars while staging correctly relies on the E3 derivation — delete dev's two pinned values; the derivation yields identical names, a no-op plan). The copy *mechanism* itself is the structural finding — see §2.2 and §3.

---

## 2. Reusability for a new client/project

Verdict up front: standing this up for a new client is closer than the finding count suggests — modules hold no env values, naming derives from four tokens, and staging proves "new environment = copy + tfvars". The blockers to *templating* it are the hardcoded residue below, the missing onboarding doc, and the workspace-objects copy mechanism.

### 2.1 Hardcoded value inventory

**In modules (violates golden rule 2 — highest scrutiny):**

| ID | Sev | Location | Value | Fix |
|---|---|---|---|---|
| R1 | should-fix | `modules/storage/main.tf:26` | `account_replication_type = "LRS"` ("Prod would revisit" — the comment admits it's an env value) | variable + allowlist validation |
| R1 | should-fix | `modules/storage/main.tf:35` | `shared_access_key_enabled = true` (= T5) | variable, default `false` |
| R2 | nice-to-have | `modules/networking/main.tf:101,108,136,225,236` | derived names via `replace(var.…_name, "snet-"/"vnet-", "")` — silently double-prefixes for clients with different CAF tokens | accept a `name_suffix` or explicit name inputs |
| R3 | nice-to-have | `modules/key-vault/main.tf:22` | `sku_name = "standard"` | variable (borderline) |
| — | documented non-knob | `modules/databricks-workspace/main.tf:37` | `public_network_access_enabled = true` | deliberate (ADR-0010); list in onboarding doc as a known invariant |

**In environment roots (should be variables/derived):**

| ID | Sev | Location | Value | Fix |
|---|---|---|---|---|
| R4 | should-fix | `environments/dev/main.tf:162` + `uc.tf:138` + `catalogs.tf:50,53` (and staging) | medallion container set `["bronze","silver","gold","catalog"]` frozen in **three unsynchronized places** — a client wanting `raw/curated/serving` edits three files in lockstep (= W6) | one `var.storage_containers` feeding all three |
| R5 | should-fix | `environments/dev/lakebase.tf:74,94` | grant **defaults** `["engineers"]` / `["users","bi_users"]` — validation runs even with `lakebase_enabled = false`, so a client whose `identity_groups` is `{admins, users}` fails plan for a disabled feature (= W3) | default `[]` (dev sets them in tfvars anyway) |
| R5 | should-fix | `environments/dev/lakebase.tf:125` | `purge_on_delete = true` hardcoded (tracked D5; = W4) | `lakebase_purge_on_delete` variable, default `false` |
| R6 | nice-to-have | `environments/dev/variables.tf:32-35` | `environment` **defaults to `"dev"`** in the byte-identical staging root (forgetting the tfvars override names everything `-dev-`), and the validation allowlist `["dev","staging","prod"]` blocks `qa`/`uat` tokens | remove the default in copied roots (force explicit); relax validation to a regex |
| R7 | nice-to-have | `environments/dev/terraform.tfvars:17,26` | dev pins `rg-networking-dbx-shared-wus3-001` / `stdbxdevwus3001` although the E3 derivation now computes both | delete both values (no-op plan) |
| — | nice-to-have | `environments/dev/main.tf:337` | `"psc-dbx-uiapi"` hardcodes the project token | `"psc-${var.project}-uiapi"` |
| — | should-fix | `shared-services/main.tf:194` | firewall `source_addresses = ["10.0.0.0/8"]` (= T10) | `var.spoke_address_ranges` |
| — | nice-to-have | `shared-services/variables.tf:70-78` | `spoke_vnet_names` declared, never referenced (dead) | delete |
| R9 | nice-to-have | `shared-services/main.tf:27-35`, `shared-services/uc.tf:33`, `environments/*/main.tf:53-64` | the hub/metastore name grammar independently spelled on both producer and consumer sides — nothing mechanical keeps them in lockstep | a tiny `modules/naming` (pure locals/outputs) consumed by both, or a CI grep |

**In tfvars (fine location, content issues):** the committed dev + shared tfvars carry the authoring org's real subscription GUID (both roots, same GUID) and a personal UPN (`environments/dev/terraform.tfvars:46`) — not secrets, and committing tfvars is documented repo policy, but every new client clones the previous deployment's identifiers (R8 below). `shared-services/terraform.tfvars:44` hardcodes the *derived* group name `grp-dbx-dev-admins` (= T9/I4). The all-zeros account id (= T3) means the committed tfvars already drifted from deployed truth.

### 2.2 Thin-root check (ADR-0003 / ADR-0009)

Metric: dev root = **40 resources + 6 data sources, ~1,900 lines** (staging byte-identical); shared-services = 13 resources, ~530 lines.

| Root file | Resources | Sanctioned in root? |
|---|---|---|
| `main.tf` | 4 RGs, 4 DNS links, 4 private endpoints, role assignments | **Yes** — exactly ADR-0003's root list (function RGs, PE+DNS glue, cross-scope RBAC) |
| `workspace-permissions.tf` | policy permissions, secret ACL | **Yes** — ADR-0009's explicit decision |
| `network-connectivity.tf` | NCC, binding, rules, azapi approvals | **Yes** — ADR-0012's state-boundary argument |
| `uc.tf` | metastore assignment, credential, external locations | **Sanctioned** (ADR-0011), but blueprint-shaped — module candidate |
| `workspace-config.tf` | 3 cluster policies, secret scope | **Not covered by any ADR's root list** — pure blueprint, module candidate |
| `catalogs.tf`, `sql-warehouse.tf`, `lakebase.tf` | catalogs/schemas/grants, warehouse, Lakebase | Not ADR-sanctioned as root; fully config-driven — module candidates |
| `shared-services/{main,uc}.tf` | hub network, optional firewall, DNS zones, metastore | **Yes** — deliberately inline, deploy-once rationale stated |

**R10 — should-fix (structural):** the reuse mechanism for the entire ~1,300-line workspace-objects layer is **verbatim file copy per environment** (E7), not modules. It demonstrably works and no drift exists today, but it scales as O(envs × files): prod is a third copy, the first dev-only hotfix silently forks the platform, and open debt (T2/A2, T12/D1-D2, R5/D5) has already been *doubled* rather than fixed once. Nothing detects divergence. Two defensible fixes: (a) extract the modules proposed in §3.3, or (b) keep verbatim-copy and add a CI job that diffs the copied files across env roots and fails on divergence. (a) is the right end-state for a client template; (b) is one script and an acceptable interim. Recommendation: (b) immediately, (a) as the §6 refactor sequence.

Minor: 9 of the root's 36 variables live outside `variables.tf` (co-located in `catalogs.tf`/`sql-warehouse.tf`/`lakebase.tf`) — legitimate style, but add a pointer comment in `variables.tf` so the must-set list is discoverable.

### 2.3 The tfvars pattern and the onboarding surface

**R8 — should-fix — pick one tfvars pattern; the current split is the worst of both.** Dev commits a real `terraform.tfvars` (org GUID + personal UPN) and has **no `.example`**; staging commits only `.example`; shared-services commits real values with no `.example`. The repo's `.gitignore` policy ("tfvars stay committed; they're non-secret env truth") is right *for a client-owned deployment repo* — but for a repo positioned as a reusable template, the committed values are the previous client's. Recommended: every root ships a complete, placeholder-valued `terraform.tfvars.example` (staging's is the model — its deliberate-omission comments are excellent); the authoring repo may keep real committed tfvars, but scrub personal identifiers; a client fork keeps the committed-tfvars policy with their values. Staging's `.example` completeness gaps: `databricks_account_auth_type`, `lakebase_capacity`, `lakebase_retention_days`, `lakebase_stopped`, and — critical until R5 lands — `lakebase_can_manage`/`lakebase_can_use`.

**Minimal new-client onboarding surface** (should become `docs/onboarding.md` — every caveat below is *already written down*, but scattered across five file-header comments a client only finds after the failing apply):

1. **Copy:** `modules/`, `shared-services/`, `environments/staging/` (the clean root — copy per target env), `scripts/bootstrap-tfstate.ps1`, root `.gitignore`, `docs/`. Don't start from `environments/dev/` until its tfvars are scrubbed.
2. **Decide the four naming tokens once** — `project`, `location` + `region_abbrev`, `instance`. They're an API contract (AGENTS.md rule 3): identical across every root or cross-state lookups 404.
3. **Manual prerequisites:** deployer is a Databricks **account admin**; **AIM enabled** on the account; note the account GUID; Lakebase feature enablement if used.
4. **Per boundary** (shared-services first, then each env): `./scripts/bootstrap-tfstate.ps1 -Environment <x> -Location <region>` → `backend.hcl` from the example (gitignored) → `terraform init "-backend-config=backend.hcl"`.
5. **Fill tfvars** — must-set list: *shared-services:* `subscription_id`, `databricks_account_id`, `tags`, `deploy_firewall` decision, hub CIDRs if 10.0.0.0/24 collides, `metastore_owner` (second apply only); *each env:* `subscription_id`, `environment`, `databricks_account_id`, `identity_groups` (must include `admins` with ≥1 real UPN), `tags`, the four spoke CIDRs, the token trio, then the grant matrices (`catalogs`, `catalog_grants`, `schema_grants`, `cluster_policy_can_use`, `secret_scope_read_groups`, `key_vault_secrets_officer_groups`, `resource_group_reader_groups`, `sql_warehouse_can_use`, and until R5: explicit `lakebase_*` lists). Leave `hub_resource_group_name`/`metastore_name`/`storage_account_name` null — the derivation is correct.
6. **Apply order with the known two-phase dances:** shared-services (metastore_owner unset) → env `apply "-target=module.databricks_workspace"` → full apply → second apply for NCC approvals (ADR-0012) → shared-services re-apply with `metastore_owner`.

---

## 3. Configurable workspace objects

### 3.1 Configurability today

| Object | Off-switch? | Multiplied? | Notes |
|---|---|---|---|
| UC catalogs/schemas/grants | yes (`{}` default) | **yes** — `for_each = var.catalogs` | **already the target pattern** (`catalogs.tf`) — the proposal below extends this design |
| Storage credential / external locations / metastore assignment | no — always created | no — layer set frozen `toset(["bronze","silver","gold"])` (`uc.tf:138`) | correct to keep unconditional (see 3.2), but the container set must be variable (R4/W6) |
| SQL warehouse | **no** — unconditional singleton | no | `min/max_num_clusters`, `warehouse_type`, serverless, photon, spot policy all hardcoded (`sql-warehouse.tf:59-70`); resource label is `dev` |
| Lakebase | **yes** — `lakebase_enabled`, count-gated | no | the only real toggle (ADR-0013 §6) — but defaults break minimal clients (R5) and `purge_on_delete` hardcoded |
| Cluster policies | **no** — three unconditional singletons | no | set frozen in **three places**: resources, `local.cluster_policy_ids`, key-allowlist validation (`variables.tf:223`) |
| Secret scope | **no** — unconditional | no | harmless but noise for non-KV clients |
| Permissions layer | yes (`{}`/`[]` = admins-only) | yes — `for_each` over grant maps | healthy; keyed by `identity_groups` logical keys |
| NCC / serverless connectivity | **no — zero variables in the file** | rules `for_each` a hardcoded local | a client that never enables serverless still gets an account-level NCC, binding, 3 PE rules, and the azapi ceremony (**W1**) |

Findings W1–W8 (severity as marked): **W1** should-fix — gate NCC behind `var.serverless_connectivity` (ADR-0012 decided *where* it lives, not that it's mandatory; ADR-0013 §6 already established the opt-in pattern). **W2** = T2. **W3/W4** = R5. **W5** should-fix — `var.sql_warehouses = map(object)`, default `{}`; the singleton contradicts the file's own header ("promotion … is a values change, not a code change"). **W6** = R4. **W7** nice-to-have — `var.cluster_policies` map dissolves the triple-freeze; ADR-0009's grant seam survives because grants already key by policy name. **W8** nice-to-have — secret scope behind a `workspace_settings` object.

### 3.2 Proposed opt-in design (drop-in signatures)

Derived strictly from arguments the current code sets; all defaults `{}`/`[]`/`false` — a new client gets **no** workspace objects until they opt in. Dev's exact current behavior is reproducible via tfvars translation, so migration is `terraform state mv` from singleton addresses to map addresses — no destroy/recreate.

```hcl
variable "storage_containers" {           # replaces 3 hardcoded lists (R4/W6)
  type    = list(string)
  default = ["catalog"]                   # 'catalog' required: UC managed storage (ADR-0011)
  validation {
    condition     = contains(var.storage_containers, "catalog")
    error_message = "storage_containers must include \"catalog\"."
  }
}

# catalogs / catalog_grants / schema_grants: KEEP AS-IS (already map-driven);
# only re-point the storage_container validation at var.storage_containers,
# and lift isolation_mode into the object: optional(string, "ISOLATED").

variable "sql_warehouses" {               # replaces the singleton (W5)
  type = map(object({
    cluster_size              = optional(string, "2X-Small")
    min_num_clusters          = optional(number, 1)
    max_num_clusters          = optional(number, 1)
    auto_stop_mins            = optional(number, 10)      # keep >=5 validation
    warehouse_type            = optional(string, "PRO")
    enable_serverless_compute = optional(bool, false)     # true requires serverless_connectivity.enabled
    enable_photon             = optional(bool, true)
    spot_instance_policy      = optional(string, "COST_OPTIMIZED")
    can_use                   = optional(list(string), []) # identity_groups keys
  }))
  default = {}
}

variable "lakebase_instances" {           # replaces the 6 lakebase_* scalars; {} = off (fixes W3/W4)
  type = map(object({
    capacity                    = optional(string, "CU_1")
    node_count                  = optional(number, 1)
    enable_readable_secondaries = optional(bool, false)
    retention_window_in_days    = optional(number, 2)     # keep 2..35 validation
    stopped                     = optional(bool, false)
    purge_on_delete             = optional(bool, false)   # was hardcoded true (D5) — default now safe
    can_manage                  = optional(list(string), [])
    can_use                     = optional(list(string), [])
  }))
  default = {}
  # enable_pg_native_login stays hardcoded false — a golden-rule invariant, not a knob
}

variable "cluster_policies" {             # replaces the frozen personal/jobs/shared trio (W7)
  type = map(object({
    cluster_type                = string  # "all-purpose" | "job"
    data_security_mode          = string  # "SINGLE_USER" | "USER_ISOLATION"
    min_workers                 = optional(number, 1)
    max_workers                 = optional(number, 2)
    max_autotermination_minutes = optional(number, 60)
    node_types                  = optional(list(string))  # null -> var.policy_node_types
    definition_overrides        = optional(any, {})       # merged last (escape hatch)
    can_use                     = optional(list(string), [])
  }))
  default = {}
}

variable "workspace_settings" {           # secret scope + future workspace_conf (W8, T11)
  type = object({
    key_vault_secret_scope = optional(object({
      enabled     = optional(bool, false)
      read_groups = optional(list(string), [])
    }), {})
  })
  default = {}
}

variable "serverless_connectivity" {      # gates the whole NCC layer (W1)
  type = object({
    enabled           = optional(bool, false)
    storage_group_ids = optional(list(string), ["blob", "dfs"])
    include_key_vault = optional(bool, false)  # ADR-0012's speculative 'vault' rule becomes opt-in
  })
  default = {}
}
```

Invariants preserved: grant lists stay keyed by `identity_groups` **logical keys** resolved through `module.workspace_access.group_display_names[...]` (ADR-0008/0009 seam); every grant list keeps its `contains(keys(var.identity_groups), g)` validation; `databricks_permissions` keeps the skip-when-empty guard; warehouses with `enable_serverless_compute = true` validate against `serverless_connectivity.enabled`. **UC enablement (`uc.tf` metastore assignment + credential) stays unconditional** — it is a load-bearing ordering dependency for identity federation and the whole grants layer; only the container/location set becomes variable.

### 3.3 Module recommendation

**Extract two modules; keep NCC in the root:**

1. **`modules/uc-objects`** — storage credential, external locations (`for_each var.storage_containers`), bindings, catalogs, schemas, grants. Inputs: connector/MI IDs, storage account name, workspace + metastore IDs, `group_display_names`, the maps above.
2. **`modules/workspace-objects`** — cluster policies + permissions, secret scope + ACLs, SQL warehouses + permissions, Lakebase instances + permissions. Both modules take explicit `providers = { databricks = … }` from the root.
3. **NCC/azapi stays in the environment root** — it is exactly ADR-0003's cross-state wiring: an account-scoped object embedding env-owned Azure IDs plus azapi mutations of Azure-side state. It just gains the `serverless_connectivity` gate.

**ADR-0009 reconciliation:** its rationale ("a grants-only module would be a valueless pass-through") was correct when the objects were hand-written root resources. That premise inverts once objects are map-driven: the natural module owns **object + its grants together** (as `lakebase.tf`/`sql-warehouse.tf` already co-locate them). Write an ADR-0014 (or 0009 addendum): "Grants live with the object they govern; object+grant pairs move into the modules; the root retains the identity seam (logical-key → display-name resolution) and cross-plane glue (metastore assignment, NCC, Azure RBAC); a *grants-only* module remains forbidden." Payoff: each env root shrinks from ~1,300 duplicated workspace-object lines to two module blocks + tfvars, and T2-class fixes propagate once instead of per-copy.

---

## 4. Identity management

Clean bill of health first, because it's earned: **zero user-level grants in dev or staging** — every grant principal resolves through group display names keyed by validated logical keys; UC object ownership is pinned to the admins *group*, not the deployer; the Access Connector chain is exactly the golden-rule-8 prescription (UAMI → `Storage Blob Data Contributor` on the one storage account); no `Contributor`/`Owner` anywhere; no subscription-scope assignments; no assignments to individuals; `tenant_id` never hardcoded; the hardcoded AzureDatabricks first-party `client_id` is a documented global constant (correct). The only individual identities anywhere are group *members* in tfvars, which is the design.

**I1 — blocker (for the new-client goal) — No "bring your own groups" mode; onboarding a client's existing Entra groups destroys their membership.**
`modules/workspace-access/main.tf:61-86`, `variables.tf:39-75`. The module only *creates* Entra groups, with **authoritative membership** ("members added by hand … are removed on the next apply") and a force-derived display name `grp-${project}-${env}-${role_token}`. A client with existing IdP-governed groups has two bad options: `terraform import` (first apply wipes every member not in tfvars) or rename to the template (most enterprise naming standards forbid it). ADR-0008 chose authoritative groups for a greenfield platform tenant and never addresses the client-owned-tenant case — a design gap, not a violation.
**Fix:** extend `var.groups` with `existing_object_id = optional(string)` (consume via `data.azuread_group`, skip creation/membership) and `display_name_override = optional(string)`; the `databricks_group` shell + `databricks_mws_permission_assignment` stay identical. Record as an ADR-0008 amendment.

**I2 — should-fix — CI/CD OIDC identity exists only in prose.** No `azuread_application`, SP, federated credential, or workflow exists anywhere (`.github/workflows/` holds only `.gitkeep`), while AGENTS.md rule 9 and golden rule 9 describe it as current reality ("apply runs only in CI"). The `github-oidc-azure` plumbing in `variables.tf:169-183` is ready but dangling. **Fix:** a small bootstrap root declaring app + SP + `azuread_application_federated_identity_credential` (environment-scoped subject, see D-S4) + narrowest-scope role assignments, plus the workflows — or an ADR recording the deferral (see also §5 doc fixes).

**I3 — should-fix — `group_owners` is never passed by any consumer.** `modules/workspace-access/variables.tf:24-37` warns that without it "every switch between human/CI applies churns ownership" — yet neither env root surfaces it. **Fix:** `ci_service_principal_object_id` variable in both roots wired to `group_owners` (value arrives with I2).

**I4 — should-fix — metastore owned by dev's admin group** = T9. Additional identity-side consequence: a dev-root destroy deletes the group (assignment → shell → group), leaving the shared metastore owned by a deleted principal.

**I5 — should-fix — placeholder account id** = T3 (fails all account-plane identity resources).

**I6 — should-fix — No explicit `databricks_entitlements` on workspace groups.** Least privilege currently holds only by Databricks defaults; a workspace admin granting `allow-cluster-create` to `grp-dbx-*-users` in the console is invisible to plan forever, and unrestricted creation bypasses cluster policies entirely (compounds T11/T12). **Fix:** explicit all-false entitlements per non-admin group (needs the workspace provider → env root or a second alias into the module).

**I7 — should-fix — Nothing requires `admins` to have ≥1 member.** The validation checks only that the key exists (`environments/dev/variables.tf:199-203`); `local.uc_owner` pins every UC object's owner to that group; with `members = []` under AIM, nobody materializes and only account admins can recover. **Fix:** `length(var.identity_groups["admins"].members) > 0` validation.

**I8 — nice-to-have — `databricks_group` `force = true` can silently adopt a same-named pre-existing account group** (`modules/workspace-access/main.tf:90-100`) and overwrite its `external_id` — hijacking an unrelated principal's grants. The Entra side has `prevent_duplicate_names`; the account side has no guard. Document the collision case, or pre-check via data source and fail loudly.

**New-client identity surface (what must become variable-driven):** the group display-name template and BYO-group inputs (I1); `ci_service_principal_object_id` (I3); a `platform_admins_group` input for shared-services replacing the derived-name string (I4/T9); `databricks_account_id` already variable but needs the placeholder guard + cross-root consistency note (I5); GitHub `org/repo` + environment list for the federation subjects (I2). Everything else identity-related is already tfvars-driven — verified: tenant derived from credential, UPNs/grant matrices in tfvars, no hardcoded display names in any grant code.

---

## 5. Documentation audit

No doc, if followed, produces a destructive or wrong-state deployment — the backend guidance and runbook command sequences all work against the current layout. But the docs lag the code by roughly two ADR generations, and the two skills contain rules that *contradict the repo's own deliberate conventions*.

### 5.1 Skills (highest-priority doc fixes — they steer every future agent session)

- **D1 — blocker — SKILL.md golden rule 5 and `references/terraform.md` §3 mandate `?ref=vX.Y.Z` git-tag module pinning; every module call in the repo is a deliberate local monorepo path** (`../../modules/…`, consistent with the architecture doc's monorepo decision). The skill runs as an isolated fork enforcing MUST rules — it will flag or "fix" working code every session. Rewrite rule 5 to the actual convention (local paths, versioned by the repo; pin providers/core; commit lock files), keeping git-tag pinning as a note for externalized modules. Also record the local-modules stance and its lockstep-upgrade consequence in an ADR so reviews stop re-litigating it (T-F13).
- **D2 — blocker — `references/terraform.md:22-30` shows a hardcoded backend block** — the exact pattern the E1 review removed (partial config + gitignored `backend.hcl`, because the storage account name is subscription-hashed). An agent following it reintroduces E1. Replace with the partial-config pattern, quoted per the PowerShell rule.
- **D3 — blocker — `references/azure.md:18,110` naming examples use long region names** (`eastus2`), violating ADR-0005 ("never the long region name") and internally inconsistent with its own §2 (`eus2`). The lookup skill answers naming questions *directly from this file* — it will hand out names that break the name-based cross-state lookups. Fix every example (and note `pep` not `pe`).
- **D4 — should-fix —** OIDC subject contradiction: AGENTS.md says repo+**branch**; `references/github-actions.md`/`azure.md` say repo+**environment**. Mutually exclusive subject formats; pick environment-scoped (matches the approval-gate design) and align AGENTS.md.
- **D5 — should-fix —** dev-lab is invisible to both skills — the forked author-review agent would flag `environments/dev-lab`'s ADR-0006-sanctioned `public_network_access_enabled = true` as golden-rule violations. Add the dev-lab exception + ADR-0006 pointer to SKILL.md or terraform.md §1.
- **D6 — should-fix —** CI is described as current reality across SKILL.md rule 9 / AGENTS.md / github-actions.md while `.github/workflows/` is empty and the runbook's documented method *is* the laptop. Add "(planned)" banners; soften rule 9 to "…once CI exists; today, follow the runbook."
- Nice-to-have: `terraform.md:115` shows unquoted `-replace=<addr>` (PowerShell splits dotted args — the repo's own convention quotes them); `terraform.md` §4 shows `~> 1.9` where code/ADR-0005 use `>= 1.9, < 2.0`.
- Verified clean: the skill rename left zero stale `azure-databricks-iac` references; the lookup skill's relative links all resolve; all cited ADR numbers/titles match; NSG tags/ports, DNS zone list, tag set, and provider pins in the references match the code exactly.

### 5.2 Architecture doc, ADRs, diagrams

- **D7 — should-fix — `azure-platform-architecture.md`:** the repo tree (l.47-61) is pre-monorepo (`infrastructure/` root, no `dev-lab/`, no `workspace-access/`, live `.github/workflows`); "UC metastore **+ group sync**" in shared-services (l.59, 84-85) contradicts ADR-0008 (AIM, env-owned groups) *and the doc's own lines 286-287*; env token list (l.102) missing `lab`; **Azure Policy guardrails claimed (l.211-213) but zero `azurerm_policy_*` resources exist repo-wide**; workspace hardening stated as MUST (l.306-309) while absent from code (= T11) — move both to the §0 Deferred list; Databricks naming tokens (l.139-143) missing `sc-`, `loc-`, `grp-`, `kv-` scope.
- **D8 — should-fix — ADR index/annotations:** README row for 0001 says "partially superseded by 0007" but the ADR body also records 0008; ADR-0007's keep-list still includes "IP access lists," removed by 0010 three days later, with no status annotation (0001/0004/0006 got them; 0002's landed follow-ups likewise unannotated).
- **D9 — should-fix — ADR-0012 is factually wrong about dev's secret scope:** "dev uses Databricks-backed secret scopes, not KV-backed" — dev's scope **is** KV-backed (`workspace-config.tf:109-116`, `keyvault_metadata`; *verified*). The same wrong sentence is copy-pasted as a code comment at `network-connectivity.tf:63-66`. Risk: 0012's follow-up says the `vault` NCC rule "can be dropped" — a reader acting on the false premise severs the private path future serverless secret access needs. ADRs are immutable: fix via an erratum note in the status field + README row, and fix the code comment (in dev, then re-copy).
- **D10 — should-fix — diagrams:** network diagram still shows "Entra → Databricks account group sync (SCIM)" in shared-services (contradicts ADR-0008) and an "Azure Policy guardrails" node (not implemented); both diagrams' env list omits dev-lab; neither shows NCC/serverless (ADR-0012) or Lakebase (ADR-0013). Verified current otherwise (optional firewall, no IP access lists, metastore placement all correct).

### 5.3 Runbooks, reviews/, structure

- **D11 — should-fix — `deploy-dev.md` has drifted from the code it deploys:** pass-2 expected adds say "2 groups" (tfvars defines **4**); "No catalogs/schemas/grants yet — a future pass" is false (`catalogs.tf` exists and is tfvars-driven; the SQL warehouse isn't mentioned at all); "from an allowed IP" appears twice (l.362, 374) though ADR-0010 removed IP access lists — the same runbook says so at l.65-66; the file table omits `catalogs.tf`/`sql-warehouse.tf`/`lakebase.tf`. Commands otherwise verified working (bootstrap params, backend flow, `-target` phases, expected counts for shared-services).
- **D12 — should-fix — the "2026-07-10 review" is cited by finding ID (E1, E3, E7, A2, B2, C9, D1-D5) from at least three places** (`staging-promotion-notes.md`, `backend.tf` headers, staging tfvars.example) **but was never committed** — `docs/reviews/` is empty. Either commit that review here or expand the IDs inline where cited. (This document begins populating the directory; keep it.)
- **D13 — should-fix — staging has no runbook** and its de-facto deployment doc is a design note. Convert `staging-promotion-notes.md` → `docs/runbooks/deploy-staging.md` (thin delta over deploy-dev; its "remaining gaps" list becomes a pre-flight checklist — several are this review's T-findings). Prod needs only a one-line "intentional stub" marker (`environments/prod/README.md`).
- **D14 — nice-to-have —** `dev-lab-profile.md` now almost fully duplicates ADR-0006 + the dev-lab README; merge §6's cost playbook into the README and delete (or banner it "historical build spec"). AGENTS.md's "## Claude Code" section duplicates CLAUDE.md — keep it in CLAUDE.md only. `copilot-instructions.md` restates ~80% of AGENTS.md and has already drifted (omits the tag rule, dev-lab, deploy order) — reduce to a 3-line pointer at AGENTS.md.

### 5.4 Target doc structure

```
docs/
├── architecture/
│   ├── azure-platform-architecture.md          KEEP — canonical; apply D7 (tree, group-sync,
│   │                                             'lab' token, Policy+hardening → Deferred)
│   ├── decisions/                               KEEP ALL (immutable) — status-line errata on
│   │   └── 0001, 0002, 0007 (per 0010), 0012 (D9); fix README index rows
│   └── diagrams/*.drawio                        KEEP — fix SCIM node, Policy node, env lists
├── runbooks/
│   ├── deploy-dev.md                            KEEP — fix D11
│   └── deploy-staging.md                        NEW — absorbs design/staging-promotion-notes.md
├── design/                                      DISSOLVE once both files are dispersed:
│   ├── dev-lab-profile.md                       → §6 cost playbook into dev-lab README, delete
│   └── staging-promotion-notes.md               → becomes runbooks/deploy-staging.md
├── reviews/                                     KEEP — this file; commit the cited 2026-07-10
│   └── 2026-07-terraform-and-docs-review.md       review too, or expand its IDs inline (D12)
├── onboarding.md                                NEW — §2.3 of this review, promoted to a doc
AGENTS.md                                        single source of rules (fold D4/D6 fixes in)
.github/copilot-instructions.md                  → 3-line pointer at AGENTS.md
CLAUDE.md                                        already correct (thin, @AGENTS.md)
.claude/skills/…                                 fix D1-D3, D5, D6; keep operational content local
```

---

## 6. Prioritized action plan

### Phase 0 — commit what exists (before anything else)

1. **PR-0:** resolve the staging tfvars rename artifact (`git rm --cached` or restore per R8), then commit the entire working set — `modules/workspace-access/`, all workspace-object files in both envs, ADRs 0007-0013, staging lock file, the lookup skill (T4). Until this lands, the platform under review doesn't exist in git.

### Phase 1 — quick wins (small, independent, high value; 1 PR each or batched)

2. **PR-1 (security):** NCC approval filter — match `endpoint_name` from the NCC rules instead of any-Pending; fixes T2 and the plan-churn (T-F10) together. Edit dev, re-copy to staging.
3. **PR-2 (correctness):** greenfield gate for the NCC approvals (`ncc_approval_enabled` or documented `-target` pre-pass) — T1. Same files as PR-1; can be one PR.
4. **PR-3 (tfvars hygiene):** real `databricks_account_id` + reject-zeros validation in three roots (T3/I5); delete dev's two pinned derived names (R7); stale TODOs.
5. **PR-4 (copied-code fixes, dev-first then re-copy):** `lakebase_purge_on_delete` var default false (R5/W4); lakebase grant defaults → `[]` (R5/W3); `kv_purge_on_destroy` var (T8); `shared_access_key_enabled` + `account_replication_type` module variables (T5/R1); admins-nonempty validation (I7).
6. **PR-5 (policy hardening):** `num_workers` bound + LTS `spark_version` allowlist in all three policies (T12); `databricks_entitlements` for non-admin groups (I6); optionally the `workspace-hardening.tf` skeleton (T11).
7. **PR-6 (docs/skills truth):** skill fixes D1-D3, D5, D6 + quoting/pinning nits; ADR errata (D8, D9 incl. the network-connectivity.tf comment); runbook fixes (D11); commit-or-expand the 2026-07-10 review (D12); AGENTS.md prod-stub + planned-CI banners (D4, D6).
8. **PR-7 (drift guard, interim):** CI script that diffs the copied files across env roots and fails on divergence (R10 option b). One script; buys safety for everything until Phase 2.

### Phase 2 — the reusability/configurability refactor (sequenced, each PR shippable alone)

9. **PR-8:** `var.storage_containers` replacing the three frozen container lists (R4/W6) — smallest structural change, unblocks per-client medallion layouts.
10. **PR-9:** map-driven workspace objects *in place* (still in the roots): `sql_warehouses`, `cluster_policies`, `lakebase_instances`, `workspace_settings`, `serverless_connectivity` per §3.2, with `moved`/`state mv` migration notes. Dev first, byte-copy to staging, tfvars translated.
11. **PR-10:** extract `modules/uc-objects` + `modules/workspace-objects` (§3.3); roots shrink to wiring + tfvars; write ADR-0014 amending ADR-0009's boundary.
12. **PR-11 (identity portability):** BYO-groups mode + display-name override in workspace-access (I1); `group_owners` wiring (I3); platform-admins group in shared-services + metastore owner transfer (T9/I4). ADR-0008 amendment.
13. **PR-12 (CI identity):** OIDC bootstrap root (app/SP/federated credentials, environment-scoped subjects) + plan/apply workflows (I2, D4/D6); wire the SP into `group_owners` and drop the laptop-apply caveats.
14. **PR-13 (docs consolidation):** target structure of §5.4 — deploy-staging runbook, onboarding.md, design/ dissolved, copilot pointer, architecture-doc refresh, diagram updates.
15. **Backlog (decide, then ADR or defer explicitly):** staging egress mode (T7); DBFS-root storage firewall (T6); firewall/NSG allowlist sync (T10); KV secret-scope runtime path test (T13); diagnostics/audit logging (T17); module `versions.tf` (T14); PE-subnet NSG (T16); naming module (R9).

---

*Review only — no Terraform or docs were modified in this pass; this file is the sole addition.*
