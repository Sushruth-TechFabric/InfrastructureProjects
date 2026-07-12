# dev-lab — Cost-Optimized Databricks Practice Environment

A personal Databricks lab that is **always available** (~$3–5/month idle) with
**strictly on-demand compute** (~$55–105/month with daily practice). Designed for a
$150/month budget, enforced in code. Full rationale:
[ADR-0006](../../docs/architecture/decisions/0006-cost-optimized-lab-profile.md) and the
[design doc](../../docs/design/dev-lab-profile.md).

Each person deploys this **into their own Azure subscription** — nothing here is shared
infrastructure. Your state, your workspace, your budget.

## What you get

| Component | Detail | Idle cost |
| --- | --- | --- |
| Databricks workspace (premium) | SCC on, front-end gated by Entra ID (ADR-0010) | $0 |
| ADLS Gen2 | `bronze` / `silver` / `gold` / `catalog` containers, default-deny firewall | ~$1–3 |
| Unity Catalog | `lab` catalog, `raw` + `curated` schemas, secretless via Access Connector | $0 |
| Single-node cluster | `lab-practice`, auto-terminates (20 min), policy-locked | $0 when terminated |
| Serverless SQL warehouse | `lab-sql`, 2X-Small, auto-stops (10 min) | $0 when stopped |
| Key Vault | RBAC-authorized, default-deny firewall | ~$0–1 |
| Budget alerts | 50% / 80% / 100% actual + 100% forecasted → your inbox | $0 |

**What it deliberately omits** vs the secure `dev` root: VNet injection, NAT Gateway,
private endpoints + private DNS — a **~$65/month delta** since
[ADR-0007](../../docs/architecture/decisions/0007-nat-gateway-nsg-egress-for-dev.md)
dropped the always-on hub firewall from dev too (the delta was ~$730/month against the
full firewall posture, still available via `deploy_firewall = true`). The lab's data
plane traverses **public endpoints behind default-deny firewalls + identity** — fine for
a lab, explicitly NOT the client posture.

## Prerequisites

- An Azure subscription where you have **Owner** (role assignments + budgets need it).
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) — logged in.
- [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.9`.
- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
  for the state-backend bootstrap script — built into the repo's tooling on Windows;
  on macOS/Linux install `pwsh` (e.g. `brew install powershell`).
- A Databricks account **auto-enabled for Unity Catalog** (all accounts created since
  ~Nov 2023 are; step 6 has the check for older accounts).

## Setup (once per person)

All commands run from `terraform/azure/databricks/` unless noted, and work as-is in
**PowerShell (Windows), Bash/Zsh (macOS/Linux), and cmd** — where a step differs per
shell, both variants are shown. Terraform flags that contain `=` are always written
quoted (e.g. `"-target=..."`); keep the quotes — they make the command parse
identically in every shell.

### 1. Log in and pick your subscription

```sh
az login
az account set --subscription "<your-subscription-id>"
az account show --query "{name:name, id:id}" -o table
```

### 2. Bootstrap the Terraform state backend

Creates the resource group + storage account that will hold your Terraform state
(separate from the lab itself, survives lab destroys).

PowerShell (Windows):

```powershell
./scripts/bootstrap-tfstate.ps1 -Environment dev-lab -Location westus3
```

Bash/Zsh (macOS/Linux):

```sh
pwsh ./scripts/bootstrap-tfstate.ps1 -Environment dev-lab -Location westus3
```

Copy the `backend "azurerm"` block values it prints at the end — you need them next.

### 3. Create your personal backend + variables files

PowerShell (Windows):

```powershell
cd environments/dev-lab
Copy-Item backend.hcl.example backend.hcl
Copy-Item terraform.tfvars.example terraform.tfvars
```

Bash/Zsh (macOS/Linux):

```sh
cd environments/dev-lab
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Both copies are **gitignored** (they are yours, not the repo's). Fill them in:

- `backend.hcl` — paste the storage account name from the bootstrap output.
- `terraform.tfvars` —
  - `subscription_id`: from step 1.
  - `storage_account_name`: globally unique — include your initials.
  - `allowed_ip_addresses`: your public IP (`curl ifconfig.me`) for the storage/Key
    Vault firewalls (the workspace front-end is Entra ID-gated, not IP-gated —
    ADR-0010). **Prefer a small CIDR range over a single IP** — if your ISP rotates
    your address, a one-IP list locks you out of storage/Key Vault. No `/31` or
    `/32` CIDRs.
  - `budget_contact_emails`: where the $75/$120/$150 alerts go.
  - `tags.Owner`: your email.

### 4. Init

```sh
terraform init "-backend-config=backend.hcl"
```

### 5. Phase 1 — create the workspace (Azure layer)

The Databricks provider can only authenticate once the workspace exists, so the first
apply is targeted:

```sh
terraform apply "-target=azurerm_databricks_workspace.this"
```

Expect a warning about `-target` — that's the point; it is intentional here.

### 6. Preflight — confirm Unity Catalog is attached

Open the workspace (portal → the `dbw-{project}-lab-...` resource → Launch Workspace) and click
**Catalog** in the sidebar. If you can browse catalogs, the regional default metastore
auto-attached — continue. If Catalog is missing/empty (older Databricks account), attach a
metastore once via [accounts.azuredatabricks.net](https://accounts.azuredatabricks.net)
(Catalog → create/assign metastore for your region), then continue.

> Since ADR-0011, the regional metastore is Terraform-managed in
> `shared-services` and shows up as `mst-dbx-shared-wus3-001`. Nothing changes
> for dev-lab — auto-attach still applies and this root still manages no
> metastore.

### 7. Phase 2 — everything else

```sh
terraform apply
```

This applies the cluster policy + cluster, SQL warehouse, and the Unity
Catalog chain. **If it fails with a 403 on the storage credential**: the role assignment
from phase 2 hasn't propagated yet (takes a few minutes). Just run `terraform apply`
again — it is safe and picks up where it left off.

### 8. Verify

- `terraform output workspace_url` → open it, log in with your Entra identity.
- **Catalog** → `lab` catalog with `raw` and `curated` schemas exists.
- **SQL Editor** → attach to `lab-sql`, run:

  ```sql
  CREATE TABLE lab.raw.hello AS SELECT 'it works' AS msg;
  SELECT * FROM lab.raw.hello;
  ```

  (First query spins the warehouse up in seconds; it auto-stops after 10 idle minutes.)
- **Compute** → `lab-practice` exists (start it only when you need Python/Spark; it
  auto-terminates after 20 idle minutes and the policy forbids changing that).

## Daily use — the cost playbook

- **Never** leave anything running manually: everything auto-stops; just close the tab.
- SQL / dbt-style practice → the **serverless warehouse** (seconds to start, $0 idle).
- Python / Spark / Delta practice → start `lab-practice` (single node, ~$0.60–0.90/hr).
- Gen AI → **Foundation Model APIs** (pay-per-token, Serving tab) — never a GPU cluster.
- Budget mails at $75 / $120 / $150. **At the $120 (80%) mail, stop scheduling new work.**
- Spend check: portal → Cost Management → Cost analysis → filter tag
  `Project = azure-databricks-platform`.
- Away for a week or more? Destroy the lab (below) — rebuilding takes minutes.

## Destroy / rebuild

```sh
terraform destroy
```

- Your Terraform **state backend, code, and docs survive** — rebuild any time by
  re-running steps 5–7 (your `backend.hcl` / `terraform.tfvars` are still on disk).
- **Data in ADLS does NOT survive** a full destroy. To keep the data lake while
  destroying the expensive-to-idle rest (rare — idle cost is already ~$3–5):

  ```sh
  terraform state rm module.storage azurerm_resource_group.storage
  terraform destroy   # storage RG + account are now unmanaged and untouched
  ```

  Re-adopt later with `terraform import`, or treat it as scratch and let it go.
- Key Vault: destroy soft-deletes it (purge protection blocks a hard purge). A re-apply
  within 7 days **recovers** the same vault automatically (`recover_soft_deleted_key_vaults`
  is enabled in providers.tf) — no name-collision dance needed.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| 403 creating `databricks_storage_credential` | RBAC propagation lag on the UAMI role assignment | Wait 2–5 min, re-run `terraform apply` |
| Storage/Key Vault access denied from your machine | Your egress IP changed (ISP rotation) and fell off the firewall allowlists | Fix `allowed_ip_addresses` in tfvars, `terraform apply` (the workspace front-end itself is Entra ID-gated, not IP-gated — you can always reach it to work) |
| `enable_serverless_compute` unsupported error | Serverless not enabled for your account/region | Set `enable_serverless = false` in tfvars — classic PRO warehouse, same auto-stop |
| Catalog sidebar empty after phase 1 | Older account without auto-UC | Attach a metastore once via accounts.azuredatabricks.net (step 6), re-apply |
| Storage account name taken | Names are globally unique | Pick another `storage_account_name` |
| Budget resource errors | Missing subscription-level permission | You need Owner (or Cost Management Contributor) on the subscription |
| Storage firewall rejects your IP rule | `/31` or `/32` CIDR passed | Use bare IPs or `/30`+ ranges |
| `terraform init` cannot reach state storage | Bootstrap allowlisted a different IP | Re-run the bootstrap script from your current network (idempotent), or add your IP: `az storage account network-rule add` |

## Guardrails you should NOT remove

- `no_public_ip = true` (SCC), the default-deny storage/Key Vault firewalls, the
  budget — they are all **free**. Removing them saves $0 and reopens the exact holes
  this design documents closing. (The workspace front-end IP access list was
  deliberately removed by ADR-0010 — front-end gating is Entra ID only.)
- The cluster policy fixes `autotermination_minutes`. If a colleague asks to disable
  auto-termination, the answer is the policy itself: that request is how $450/month
  clusters happen.
