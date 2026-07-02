# GitHub Copilot — repository instructions

This is a secure Azure Databricks platform (Terraform + GitHub Actions).

The authoritative, shared rules for all agents are in **`AGENTS.md`** at the repo
root, and the full architecture decisions + network diagram are in
**`docs/architecture/azure-platform-architecture.md`**. Follow those. The most
load-bearing rules to keep in mind on every change:

- Modules contain no environment-specific values; one Terraform state file per
  deployment boundary (`environments/<env>` and `shared-services` each own theirs).
- Cross-state dependencies are resolved with **Azure data sources looked up by
  name** — never `terraform_remote_state`, never hardcoded resource IDs. The
  naming convention `{type}-{workload}-{env}-{region}-{instance}` is a contract.
- Networking is hub-spoke with forced tunneling to the hub firewall and
  private endpoints + linked Private DNS zones for every PaaS service.
- Databricks: SCC (no public IP), **back-end** Private Link for the compute plane;
  the front-end is internet-reachable, gated by Entra ID + workspace IP access lists
  (no front-end Private Link). Data/secret planes stay private. Cluster policies
  enforce VNet injection + SCC. The Unity Catalog metastore is account-level
  (one per region) and lives in `shared-services`, not an environment root.
- Data access is **secretless**: Access Connector with a user-assigned managed
  identity + `Storage Blob Data Contributor`. No keys, SAS, or SP secrets.
- Identity: user-assigned managed identities by default; CI/CD via OIDC federated
  credential scoped to this repo + branch. RBAC uses narrowest scope, most
  specific built-in role, assigned to groups — never `Owner` for automation.
- Never write secrets into tracked files. Never relax a private-only path without
  an explicit instruction.
