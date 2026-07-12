# AGENTS.md

Secure, enterprise **Azure Databricks** platform built with **Terraform** and
**GitHub Actions**. This file is the shared instruction set for all coding agents
(Codex, Copilot, Cursor, Kimi, etc.). Claude Code reads it via the `@AGENTS.md`
import in `CLAUDE.md`.

> **Full architecture decisions + rationale + network diagram live in**
> [`docs/architecture/azure-platform-architecture.md`](docs/architecture/azure-platform-architecture.md).
> Read it before generating or modifying infrastructure. The rules below are the
> condensed, must-follow subset.

## Stack
- Terraform (azurerm + databricks providers), remote state in Azure Storage.
- Azure: hub-spoke networking, Databricks (VNet injection), ADLS Gen2, Key Vault,
  Unity Catalog, Entra ID.
- CI/CD (planned): GitHub Actions with OIDC (no stored secrets). The workflows
  don't exist yet (`.github/workflows/` is empty) — until they do, applies
  follow `docs/runbooks/deploy-dev.md`.

## Repository layout
- `modules/` — reusable blueprints, **no environment-specific values**.
- `environments/{dev,staging,prod}/` — one root config + **one state file** each.
- `environments/dev-lab/` — per-person cost-optimized practice lab (ADR-0006): no
  hub/VNet-injection/private endpoints; every free control kept. A documented
  exception to rules 5–6 below, scoped to that root only; setup in its README.
- `shared-services/` — hub network, DNS, **UC metastore (ADR-0011)**, deploy-once
  infra (own state). The metastore is account-level (one per region), so it lives
  here, not in an environment root. Identity sync is **AIM** (no sync infra to
  deploy) — env-scoped access groups live in each env root via
  `modules/workspace-access` (ADR-0008).
- Deploy order: shared-services → spoke networking → security → workloads.

## Hard rules (MUST)
1. **No env values in modules.** One state file per deployment boundary.
2. **Cross-state lookups use Azure data sources by name** (e.g. `azurerm_subnet`).
   Never `terraform_remote_state`; never hardcode resource IDs.
3. **Naming convention is an API contract:**
   `{type}-{project}-{env}-{region}-{instance}` (abbreviate where Azure limits
   length; storage/Key Vault have special limits). Name-based lookups depend on it.
4. **Tag every resource:** `Environment`, `Owner`, `CostCenter`,
   `ManagedBy=terraform`, `Project`.
5. **Networking:** two delegated Databricks subnets (`/26`+, prefer `/23`–`/24` in
   prod) + a separate private-endpoint subnet; VNet `/16`–`/24`. Exactly ONE egress
   mode per spoke (ADR-0007): forced tunneling (`0.0.0.0/0` → hub firewall) with an
   egress allowlist — the prod/client posture — or spoke NAT Gateway + NSG
   service-tag allowlist with deny-Internet (current dev default; the hub firewall
   is behind `deploy_firewall = false` in shared-services). Private endpoints +
   linked Private DNS zones for every PaaS service in both modes (forgetting the
   DNS link is the classic silent failure).
6. **Databricks security:** SCC on (no public IP); **back-end** Private Link for the
   compute plane. The **front-end is internet-reachable, gated by Entra ID** (no
   front-end Private Link, no user VNet path, no workspace IP access lists — ADR-0010).
   Data and secret planes stay private (storage/Key Vault public access **disabled**).
7. **Data access is secretless:** Access Connector with a **user-assigned managed
   identity** + `Storage Blob Data Contributor`. No account keys / SAS / SP secrets.
   Governance via Unity Catalog; secrets only via Key Vault-backed scopes.
8. **Cluster policies** force VNet injection + SCC on every cluster; harden the
   workspace to least functionality.
9. **Identity:** user-assigned managed identities by default. CI/CD (planned)
   authenticates via a **federated (OIDC) credential** scoped to this repo +
   GitHub **environment** (the approval-gate design) — no secrets. Until CI
   exists, applies follow the runbook.
10. **RBAC:** narrowest scope, most specific built-in role (not `Contributor`/
    `Owner`), assign to **groups** not individuals. Automation principals never get
    `Owner`. All assignments in Terraform.

## Boundaries
- **Never** put secrets, keys, or credentials in any tracked file (this file is
  committed and logged).
- **Never** widen public network access or relax a private-only path without an
  explicit instruction and a stated reason.
- If a request conflicts with a rule above, **surface the conflict** instead of
  silently complying.

## Validation before proposing changes
- `terraform fmt -check` and `terraform validate` must pass.
- Run `terraform plan` for the target environment; never auto-apply to `prod`.

<!-- Tool-specific notes (humans only; most agents read the whole file) -->
## Claude Code
- Use plan mode for multi-resource changes. Prefer editing modules over
  duplicating resources into a root config.
