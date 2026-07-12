# Runbook — Deploy the `dev` environment

Step-by-step guide to stand up (and tear down) the secure Databricks dev
environment. Explains what each step does, what each command does, and what to
look for when reviewing the plans. Architecture rationale lives in
[`docs/architecture/azure-platform-architecture.md`](../architecture/azure-platform-architecture.md);
this document is purely operational.

> **Cost context (ADR-0007):** dev now egresses via a spoke NAT Gateway + NSG
> allowlist — the Azure Firewall is **not deployed by default**
> (`deploy_firewall = false` in `shared-services/terraform.tfvars`). Idle cost
> with everything applied is **~$70/month** (4 private endpoints ~$29, NAT
> Gateway ~$33 + data, public IP ~$4, DNS zones ~$2), so leaving dev running is
> affordable; same-day teardown (Step 6) is still the cheapest habit. If you
> flip `deploy_firewall = true` for forced-tunneling practice, the old warning
> applies in full: ~$1.25/hr firewall + NAT + IPs (~$30/day) from the moment of
> apply — destroy the same day.

---

## The files, and what each one does

Every deployment boundary (`shared-services`, `environments/{dev,staging,prod}`) is a
self-contained Terraform root with **its own state file**. Within each root:

| File | Role |
|---|---|
| `backend.tf` | Where state lives — an Azure Storage blob, authenticated via your Entra identity (`use_azuread_auth = true`), no storage keys. Partial config (empty `backend "azurerm" {}`); the actual resource group / storage account / container / key come from a gitignored `backend.hcl` (copy from the committed `backend.hcl.example`) passed at `init` time — see Step 1. |
| `providers.tf` | Pins Terraform + provider versions; configures `azurerm` (Azure resources) and, in dev, `databricks` (workspace-level settings), `databricks.account` (account-level: identity ADR-0008, UC ADR-0011, serverless NCC ADR-0012), `azuread` (Entra groups) and `azapi` (approve the inbound serverless PE connections, ADR-0012). shared-services also carries `databricks.account` for the metastore. |
| `network-connectivity.tf` (dev) | Serverless private connectivity (ADR-0012): the account-level Network Connectivity Config + private endpoint rules (blob/dfs/vault) + workspace binding, and the azapi approval of the Databricks-raised connections. Two-phase apply (Step 4b). |
| `uc.tf` | Unity Catalog (ADR-0011). shared-services: the account-level **metastore** (one per region, import-or-create). dev: metastore **assignment** (by-name lookup) + **storage credential** + the **external locations** (`catalog` plus one per medallion layer) that `catalogs.tf` builds on. |
| `catalogs.tf` (dev) | UC catalogs / schemas / grants **as config**: driven entirely by the `catalogs` / `catalog_grants` / `schema_grants` tfvars maps (group-based, ADR-0009). Add or remove by re-applying. |
| `variables.tf` | Declares inputs (types, descriptions) — no values. |
| `terraform.tfvars` | The **only place the environment's concrete values live**: subscription id, CIDRs, names, tags. Non-secret by design. |
| `main.tf` | Instantiates the reusable modules and does cross-boundary glue: hub DNS-zone lookups, DNS zone links, private endpoints, RBAC. |
| `workspace-config.tf` (dev) | "Pass 2" — controls *inside* the workspace: cluster policies, Key Vault-backed secret scope. |
| `workspace-permissions.tf` (dev) | Grants on those workspace objects (ADR-0009): which identity groups may CAN_USE each cluster policy and READ the secret scope, driven by the tfvars matrix. |
| `sql-warehouse.tf` (dev) | Classic SQL warehouse (2X-Small, PRO, aggressive auto-stop — the dev cost posture) + its CAN_USE grants from `sql_warehouse_can_use`. |
| `lakebase.tf` (dev) | Lakebase managed Postgres (ADR-0013), **opt-in** via `lakebase_enabled` (creates nothing when `false`): the database instance + its group grants (Step 4c). |
| `outputs.tf` | Values printed after apply (names, IPs, workspace URL). |

`modules/` (networking, storage, key-vault, identity, databricks-workspace) are
environment-agnostic blueprints — every environment calls the same module code
with different tfvars. `scripts/bootstrap-tfstate.ps1` solves the chicken-and-egg
problem: Terraform needs somewhere to store state before Terraform can run, so
the state storage account is created once with the Azure CLI.

**Deploy order is not optional.** Dev resolves the four Private DNS zones and
the UC metastore — its hub dependencies in NAT-egress mode (ADR-0007/0011) —
**by name via data sources at plan time** (the cross-state contract — no
`terraform_remote_state`, no hardcoded IDs). Until shared-services is applied,
`terraform plan` in dev fails with "not found" errors on the zones and the
metastore. That is the contract working as designed.

---

## Step 0 — Prerequisites

```powershell
az login
az account set --subscription <dev-subscription-guid>   # must match terraform.tfvars
terraform version    # >= 1.9 required (pinned in providers.tf)
curl ifconfig.me     # your current public egress IP
```

Your egress IP must be on the state storage accounts' firewall allowlists (set
at bootstrap; add with `az storage account network-rule add` if your IP
changed) — otherwise `terraform init` cannot reach state. (The workspace
front-end itself is Entra ID-gated, not IP-gated — ADR-0010.)

**Account-level prerequisites (ADR-0008 identity, ADR-0011 metastore)** —
shared-services now creates the UC metastore and dev pass 2 creates the
workspace access groups + metastore assignment, so before the first apply of
either:

1. At <https://accounts.azuredatabricks.net>: confirm **Automatic Identity
   Management is Enabled** (Security → User provisioning) — hard prerequisite;
   AIM is what syncs group membership from Entra, Terraform deliberately does
   not.
2. Record the **account id** (GUID in the account console) into
   `databricks_account_id` in **both** `shared-services/terraform.tfvars` and
   `environments/dev/terraform.tfvars`. An identifier, not a secret.
3. Confirm the identity you `az login` with is a Databricks **account admin**
   (account console → User management) — a workspace admin is not enough — and
   can create Entra groups in the tenant.
4. If a group named `grp-dbx-dev-<role>` (admins / users / engineers /
   bi_users) already exists in Entra, `terraform import` it first — the apply
   otherwise fails on the duplicate-name guard (by design; it never silently
   creates a duplicate).

## Step 1 — Bootstrap the state backends (once per boundary, likely already done)

```powershell
./scripts/bootstrap-tfstate.ps1 -Environment shared -Location westus3
./scripts/bootstrap-tfstate.ps1 -Environment dev    -Location westus3
```

Creates `rg-tfstate-<project>-<env>-wus3-001` with a hardened storage account
(`-Project` defaults to `dbx`; pass it explicitly when reusing the script for
another project): TLS 1.2
minimum, default-deny firewall allowlisting your IP, blob versioning + 30-day
soft delete (state recovery), a `CanNotDelete` lock, and a
`Storage Blob Data Contributor` grant to you (the backend uses data-plane Entra
auth, so control-plane Owner is not enough). The account name embeds a
subscription-derived hash. Idempotent; re-running converges and never deletes.

`backend.tf` in every root is a **partial** config (empty `backend "azurerm" {}`)
so the deployer/subscription-specific storage-account name never lands in a
committed file. For each boundary: copy `backend.hcl.example` → `backend.hcl`
(gitignored) in that root, paste the script's output into it, then pass it at
init:

```powershell
terraform init "-backend-config=backend.hcl"
```

(Keep the quotes — PowerShell splits an unquoted `-key=value` arg on the dot,
so the command only behaves the same way across shells when quoted.)

Skip bootstrapping if the backend already exists (e.g. `az group exists --name rg-tfstate-dbx-dev-wus3-001`
returns `true`) — just recreate your local `backend.hcl` with the existing values.

## Step 2 — Deploy shared-services (the hub + UC metastore)

**Metastore import-or-create first (ADR-0011).** The metastore is account-level,
one per region, and the account is UC auto-enabled — a westus3 metastore very
likely already exists (dev-lab workspaces auto-attach to it). Check before
planning:

```powershell
# account console -> Catalog, or:
$env:DATABRICKS_HOST = "https://accounts.azuredatabricks.net"
$env:DATABRICKS_ACCOUNT_ID = "<account-guid>"
databricks account metastores list        # rides az login
```

- **A westus3 metastore exists (expected):** verify its region really is
  `westus3` (`region` is ForceNew — a mismatch plans a replace, which
  `prevent_destroy` then blocks), then import and let Terraform rename it in
  place to the convention name:

  ```powershell
  terraform import "databricks_metastore.this" "<metastore-uuid>"
  ```

  The subsequent plan must be **0 to add, 1 to change, 0 to destroy** — an
  in-place rename to `mst-dbx-shared-wus3-001` (cosmetic for dev-lab, which
  keeps auto-attaching to the same metastore). Anything else: stop and read
  the diff.
- **No metastore in the region:** nothing to import; the plan below simply
  shows it as 1 more to add.

```powershell
cd shared-services
terraform init "-backend-config=backend.hcl"
terraform plan -out=tfplan-shared
# review the diff (see "Reviewing the plans" below)
terraform apply tfplan-shared
```

- `init` — wires the directory to its remote state blob and installs the exact
  provider versions recorded in `.terraform.lock.hcl`.
- `plan -out=` — computes the diff between config, state, and real Azure, and
  saves it so `apply` executes **exactly** what was reviewed, nothing recomputed.
  A saved plan goes stale if reality changes — re-plan rather than applying an
  old file.
- `apply <planfile>` — executes the reviewed plan. Fast now: with the default
  `deploy_firewall = false` (ADR-0007) there is no firewall to wait on.

Expected on a fresh subscription: **7 to add, 0 to change, 0 to destroy** —
hub RG, hub VNet (10.0.0.0/24) with `AzureFirewallSubnet` (the name is an Azure
requirement; kept even without a firewall so the firewall mode can return
without subnet churn), and the four Private DNS zones (blob, dfs, vaultcore,
azuredatabricks) — plus the metastore as **1 change** (imported, rename-only)
or **1 more to add** (fresh region), per the import-or-create check above. With `deploy_firewall = true` add the firewall + policy +
egress rule collection, NAT gateway + 2 public IPs + 2 associations (ADR-0004 —
this is why the firewall is non-zonal); the firewall alone takes **10–15
minutes** and bills ~$1.25/hr from apply.

**`metastore_owner` on a brand-new subscription (ADR-0011 follow-up):**
`terraform.tfvars` sets `metastore_owner = "grp-dbx-dev-admins"`, but that
group doesn't exist yet on this very first apply — it's created by
environments/dev pass 2 (Step 4 below). Comment the value out (or set it to
`null`) for this first shared-services apply; once Step 4 has created the
group, uncomment it and re-run `terraform apply` here — an in-place update,
no replacement. If you're re-running this runbook against an environment
that's already past Step 4, the group already exists and this apply just
works.

## Step 3 — Deploy dev, pass 1 (Azure infra layer)

```powershell
cd ../environments/dev
terraform init "-backend-config=backend.hcl"
terraform plan "-target=module.databricks_workspace" -out=tfplan-dev-p1
# review, then:
terraform apply tfplan-dev-p1
```

**Why `-target`:** `providers.tf` points the `databricks` provider at the
workspace this same config creates (`azure_workspace_resource_id`). On a fresh
deploy the workspace does not exist, so the provider cannot authenticate and a
full plan fails on every `databricks_*` resource with
`failed to validate workspace_id`. Targeting the workspace module first builds
just its dependency chain: resource groups → spoke VNet, delegated host +
container subnets, NSGs + egress rules, NAT Gateway + public IP on both
delegated subnets (the NAT egress mode, ADR-0007) → the SCC / VNet-injected
workspace. This two-phase ordering is documented in `providers.tf` and
ADR-0002.

## Step 4 — Deploy dev, pass 2 (everything else)

**UC assignment import check first (ADR-0011).** New workspaces auto-attach to
the regional default metastore. If the workspace already shows a catalog
browser (workspace → Catalog), import the assignment instead of relying on
create over an existing attachment:

```powershell
terraform import "databricks_metastore_assignment.this" "<numeric-workspace-id>|<metastore-uuid>"
# numeric workspace id: terraform output, or the workspace URL's adb-<id> part
```

```powershell
terraform plan -out=tfplan-dev-p2
# review, then:
terraform apply tfplan-dev-p2
```

Creates the remaining Azure resources — ADLS Gen2 (bronze/silver/gold, plus the
`catalog` container for future UC managed-table storage), Key
Vault, Access Connector + user-assigned identity, the four Private DNS zone
**links** (forgetting these is the classic silent failure: the PE exists but
names still resolve to public IPs; the links do NOT need VNet peering — there
is none in NAT-egress mode), four private endpoints (blob, dfs, vault,
databricks back-end), and the
`Storage Blob Data Contributor` grant to the connector identity (secretless
data access) — plus the in-workspace controls from `workspace-config.tf`:
three cluster policies (personal / jobs / shared) and the
Key Vault-backed secret scope.

Pass 2 also applies the **identity layer** (`module.workspace_access`,
ADR-0008): per group in `identity_groups`, an Entra group (authoritative
membership — the tfvars list IS the group), a thin Databricks account "shell"
linked by `external_id`, and the workspace permission assignment
(ADMIN/USER). Expected adds with the default four groups (admins / users /
engineers / bi_users): 4 `azuread_group`, 4 `databricks_group`,
4 `databricks_mws_permission_assignment`. Membership
itself is synced by AIM at auth time (≤5 min browser login / ≤40 min
token-job auth) — no member resources appear in the plan, by design. If an
assignment fails with `Principal not in workspace` (provider issue #5367,
eventual consistency), simply re-apply — it converges.

**On a first-ever deploy:** once `grp-dbx-dev-admins` exists after this step,
go back and uncomment `metastore_owner` in `shared-services/terraform.tfvars`
and re-apply shared-services (see the callout in Step 2) — the metastore's
owner can only be set now that the group is real.

Pass 2 also enables **Unity Catalog** (`uc.tf`, ADR-0011): the metastore
assignment (add — or no-op if imported above), the storage credential
`sc-dbx-dev-wus3-001` wrapping the Access Connector identity, and the external
locations — `loc-catalog-dbx-dev-wus3-001` for the catalog's managed storage
plus one per medallion layer (bronze/silver/gold), each workspace-bound.
`skip_validation = true` on the locations is deliberate: the storage
account is sealed (public access off) and UC's create-time probe comes from the
Databricks control plane; real access flows through the VNet private endpoints
at first cluster use. If the credential apply 403s, that is RBAC propagation
lag on the blob-contributor grant — re-run `terraform apply`, it converges.

Catalogs, schemas, and UC grants are **tfvars-driven config** (`catalogs.tf`,
group-based per ADR-0009 — never individuals). With the default dev tfvars,
expect: 1 `databricks_catalog` (`dbx_dev`, managed storage on the `catalog`
container) + its workspace binding, 3 `databricks_schema` (bronze/silver/gold,
one per layer container), 1 catalog-level and 3 schema-level
`databricks_grants` from the `catalog_grants`/`schema_grants` matrices.

Pass 2 also creates the **SQL warehouse** (`sql-warehouse.tf`): 1
`databricks_sql_endpoint` (2X-Small, PRO, 10-min auto-stop — the dev cost
posture) and 1 `databricks_permissions` granting CAN_USE per
`sql_warehouse_can_use` (engineers and bi_users in the default dev tfvars;
admins implicit). Lakebase is separate and opt-in — Step 4c.

On top of the identity layer, pass 2 wires the **workspace-object permissions**
(`workspace-permissions.tf`, ADR-0009). Expected adds with the default dev
matrix: 2 `databricks_permissions` (CAN_USE on the personal and shared policies
for `grp-dbx-dev-users`; the jobs policy intentionally gets none — admins-only)
and 1 `databricks_secret_acl` (READ on `kv-dbx-dev` for the same group). The
grants are authoritative per policy: UI-added grants not in
`cluster_policy_can_use` are reverted on the next apply.

## Step 4b — Serverless private connectivity (NCC, ADR-0012)

Only needed to let **serverless** compute (serverless SQL, model serving, vector
search, Lakebase) reach the PE-only ADLS / Key Vault — serverless runs in a
Databricks-managed plane the spoke network does not cover. Skip if you never use
serverless features; nothing else depends on it.

`network-connectivity.tf` adds the `azapi` provider, so refresh the lockfile once:

```powershell
terraform init -upgrade    # pulls Azure/azapi into .terraform.lock.hcl
```

Then a **two-phase apply** — Databricks raises the private endpoint connection
from its managed subscription, so it lands **Pending** on our storage / Key Vault
and we must approve it. `azapi` approves it, but the approval data sources read
current Azure state at plan time, so the Pending connections only appear on the
*second* pass (same shape as the pass-1/pass-2 workspace ordering):

```powershell
# Phase 1 — create the NCC + rules + binding (connections go Pending)
terraform plan -out=tfplan-ncc-p1        # adds: 1 NCC, 3 PE rules (blob/dfs/vault), 1 binding
terraform apply tfplan-ncc-p1

# Phase 2 — approve the now-Pending connections
terraform plan -out=tfplan-ncc-p2        # adds: azapi_update_resource per Pending connection
terraform apply tfplan-ncc-p2
```

Confirm the paths are live (allow a few minutes to propagate):

```powershell
terraform output serverless_pe_connection_state   # each of blob/dfs/vault => ESTABLISHED
```

Or Portal → the storage account / Key Vault → **Networking → Private endpoint
connections**: the Databricks-raised connections show **Approved**. Storage and
Key Vault public access stays **disabled** throughout — this only adds a private
path, it never widens public access (golden rule intact).

**Teardown:** `terraform destroy` removes the Databricks-managed endpoints; the
Pending/Approved connection objects clear with them — no manual cleanup.

## Step 4c — Lakebase (managed Postgres / OLTP, ADR-0013)

Optional — only if you want the serverless Postgres instance (`lakebase.tf`).
Nothing else depends on it. It is **opt-in**: set `lakebase_enabled = true` in
`terraform.tfvars` (dev already does); left `false`, the file creates nothing.

**Console prerequisite (one-time, not Terraform).** Lakebase must be enabled for
the workspace/account (serverless on in-region). There is **no** Terraform
resource that toggles it; if it is off, `databricks_database_instance` fails
create with a "feature not enabled" error. Verify in the account console
(Previews / workspace settings) before applying — same shape as the AIM /
metastore prerequisites in Step 0.

```powershell
terraform plan -out=tfplan-lakebase     # adds: 1 database_instance, 1 permissions
terraform apply tfplan-lakebase
```

Review points on the plan:

- `enable_pg_native_login = false` and **no** password/secret attribute anywhere
  (secretless — connections use a Databricks OAuth token, not a PG password).
- `capacity = CU_1`, `retention_window_in_days = 2`, single node — the dev cost posture.
- `databricks_permissions` shows CAN_MANAGE for `grp-dbx-dev-engineers` and
  CAN_USE for `grp-dbx-dev-users` / `grp-dbx-dev-bi_users` (admins implicit).

Verify:

```powershell
terraform output lakebase_state            # AVAILABLE
terraform output lakebase_read_write_dns   # a hostname (not a secret)
```

Workspace → **Compute → Database instances** shows `lb-dbx-dev-wus3-001` with the
group grants. Connect from the SQL editor or `psql` using a Databricks OAuth token
(no password) as a member of a granted group; a member of no granted group is denied.

**Cost lever:** set `lakebase_stopped = true` in `terraform.tfvars` → apply to
pause the instance (storage-only billing); flip back to `false` to resume.
**Teardown:** `terraform destroy` (`purge_on_delete = true` clears storage cleanly).

## Step 5 — Verify

```powershell
terraform output          # workspace URL, resource names
```

Open the workspace URL and log in with Entra ID — the front end is
internet-reachable and Entra-gated, no IP allowlist (ADR-0010). Launch a
policy-governed cluster — if it hangs at startup, the first suspect is the NSG
egress allowlist (`nat_egress_allow_rules` in `modules/networking/main.tf`):
reconcile it against the current region-specific Databricks endpoint list on
Microsoft Learn. (In firewall mode the same suspect is the firewall policy's
`TODO(region-endpoints)` in `shared-services/main.tf`.)

**Identity layer (ADR-0008):**

- **Idempotency:** immediately re-run `terraform plan` — it must be empty.
- In the account console all four groups show source "Microsoft Entra ID", list
  the workspace under Workspaces, and membership editing is blocked
  (read-only — AIM owns it).
- **Access:** a `users`-group member reaches the workspace without admin
  settings; an `admins`-group member sees admin settings.
- **Revocation:** remove a test UPN from `identity_groups` → apply → the user
  leaves the Entra group immediately; workspace access ends within the AIM
  refresh window (≤5/40 min) plus any residual session. Their account-console
  user record may linger inactive — harmless.
- **Drift:** hand-add someone in the Entra portal → `terraform plan` shows the
  removal (authoritative membership); apply reverts it.

**Unity Catalog (ADR-0011):**

- Workspace → Catalog shows the workspace attached to
  `mst-dbx-shared-wus3-001` (top-left metastore indicator / Catalog browser
  present).
- `databricks storage-credentials list` shows `sc-dbx-dev-wus3-001`;
  `databricks external-locations list` shows `loc-catalog-dbx-dev-wus3-001`
  plus `loc-{bronze,silver,gold}-dbx-dev-wus3-001` (run against the workspace
  host).
- **Idempotency:** re-run `terraform plan` — empty.
- Readiness, not proof-of-access: actual reads/writes through the credential
  are exercised when the first catalog + cluster use it (the control plane
  cannot probe the sealed storage — that is why `skip_validation` is set).

**Workspace-object permissions (ADR-0009):**

- **Positive:** a `users`-group member's cluster-create UI shows exactly the
  personal and shared policies (no jobs policy, no unrestricted option), and a
  notebook `dbutils.secrets.get("kv-dbx-dev", "<existing-key>")` succeeds.
- **Negative:** a workspace user in no granted group sees no policies and gets
  `PERMISSION_DENIED` on the scope.
- **API spot-check:** `databricks permissions get cluster-policies <policy-id>`
  lists only `grp-dbx-dev-users: CAN_USE` (admin access is implicit, never
  listed); `databricks secrets list-acls kv-dbx-dev` shows the group READ plus
  the scope creator's MANAGE (expected, not drift).
- **Drift:** hand-grant CAN_USE to any other principal in the policy UI →
  `terraform plan` shows the in-place update removing it (authoritative). Note
  the one blind spot: a secret ACL added out-of-band via the CLI is *invisible*
  to plan — audit with `list-acls` occasionally.
- **Revocation:** remove `"users"` from `secret_scope_read_groups` → apply →
  the ACL is destroyed; removing a policy's last group reverts that policy to
  admins-only.

## Step 6 — Tear down (optional since ADR-0007)

```powershell
cd environments/dev && terraform destroy        # spoke first

cd ../../shared-services
terraform state rm databricks_metastore.this    # keep the account object (ADR-0011)
terraform destroy                               # hub second
```

Reverse order: the hub cannot cleanly delete while the spoke's DNS zone links
still reference it. The metastore has `prevent_destroy` — it is a shared
account object (dev-lab attaches to it), so destroy fails until it is removed
from state; `state rm` keeps it alive in the account, and the next cycle
re-imports it (Step 2). The state backends stay (they cost pennies) so the next
session starts at Step 2.

With the firewall off, idle dev costs ~$70/month — leaving it up between
sessions is a legitimate choice; destroy when idle for longer stretches. If you
deployed with `deploy_firewall = true`, teardown the same day is mandatory
(~$30/day otherwise).

---

## Reviewing the plans — what to actually check

The plan diff is the review artifact; the version number is not. Line-by-line
checklist for the dev plans:

- **Sealed data plane:** `public_network_access_enabled = false` on the storage
  account and Key Vault; `no_public_ip = true` (SCC) on the workspace.
- **DNS:** every `azurerm_private_endpoint` has a `private_dns_zone_group`
  block, and every zone used has a matching
  `azurerm_private_dns_zone_virtual_network_link` to the spoke VNet.
- **RBAC:** exactly `Storage Blob Data Contributor`, scoped to the single
  storage account, principal = the Access Connector's user-assigned identity.
  No `Contributor`/`Owner` anywhere.
- **Egress (NAT mode, ADR-0007):** the NAT Gateway (+ its public IP) is
  associated to **both** Databricks subnets; both NSGs get the five
  service-tag allow rules plus `DenyAllInternetOutbound` (4096). No route
  table should appear. (In firewall mode instead: the route table sends
  `0.0.0.0/0` to the hub firewall's private IP and is associated to both
  Databricks subnets.)
- **Tags:** `Environment`, `Owner`, `CostCenter`, `ManagedBy=terraform`,
  `Project` on every resource.
- **On re-runs:** anything under `to change` or `to destroy` needs an
  explanation before apply — a create-only plan is the safe baseline.

## Failure modes seen in practice

| Symptom | Cause |
|---|---|
| `terraform init` → 403 on the backend | Your egress IP is not on the state storage firewall, or you lack `Storage Blob Data Contributor` (data-plane) on the account. |
| Dev plan: 4 × "not found" (Private DNS zones) | shared-services not applied yet — deploy order. |
| Dev plan: metastore "not found" on `data.databricks_metastore` | shared-services not applied yet (deploy order), `metastore_name` doesn't match what shared-services derived, or the deployer is not an account admin. |
| UC apply: 403 / `PERMISSION_DENIED` on `databricks_storage_credential` | RBAC propagation lag on the blob-contributor grant, or the workspace isn't attached to the metastore yet — re-apply, it converges. |
| UC apply: assignment conflict (workspace already has a metastore) | Auto-attach beat you to it — `terraform import "databricks_metastore_assignment.this" "<workspace_id>\|<metastore_id>"` (Step 4). |
| shared-services destroy: `Instance cannot be destroyed` on the metastore | `prevent_destroy` working as designed — `terraform state rm databricks_metastore.this` first (Step 6). |
| Dev plan: `failed to validate workspace_id` on `databricks_*` | Workspace doesn't exist yet — run the pass-1 `-target` apply first. |
| Cluster hangs at launch | Egress allowlist missing a required Databricks control-plane endpoint — NSG service-tag rules (NAT mode) or firewall policy (firewall mode). |
| PE exists but connections fail with public-IP resolution | Missing Private DNS zone **link** to the spoke VNet. |
| Identity apply: 401/403 or `Principal not found in account` on `databricks_group` / assignment | You are not a Databricks **account admin** (workspace admin is not enough), or `databricks_account_id` is wrong. |
| Identity apply: `A group already exists with the display name ...` | The group pre-exists in Entra — `terraform import module.workspace_access.azuread_group.this[\"<key>\"] <object-id>` (the duplicate-name guard working as designed). |
| Identity apply: `Principal not in workspace` on an assignment | Provider issue #5367 (eventual consistency) — re-apply. |
| Member added to a group, but no workspace access yet | AIM syncs at auth activity: ≤5 min browser login / ≤40 min token auth. Not a Terraform issue. |
| Grant apply: `Group grp-dbx-dev-... does not exist` on `databricks_permissions` / `databricks_secret_acl` | Workspace assignment eventual consistency (same family as #5367) — re-apply, it converges. |
| Serverless query can't read data; NCC connections stuck `Pending` | Approval phase not applied yet — run the Step 4b phase-2 apply; `terraform output serverless_pe_connection_state` should read `ESTABLISHED`. |
| NCC apply: `Principal not found in account` / 401 on `databricks_mws_*` | Not a Databricks **account** admin, or wrong `databricks_account_id` — same prerequisite as identity/metastore (Step 0). |
| Lakebase apply: `feature not enabled` / not-found on `databricks_database_instance` | Lakebase not enabled for the workspace/account — the Step 4c console prerequisite (no Terraform toggle exists). |
| Lakebase plan: duplicate `access_control` / duplicate principal | A group appears in both `lakebase_can_use` and `lakebase_can_manage` — the disjoint-lists validation should catch it; give each group one level. |
