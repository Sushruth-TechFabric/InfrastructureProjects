# Azure — best practices, cheat codes, docs

## Table of contents
1. Naming & tagging
2. Resource groups & subscriptions
3. Hub-spoke networking
4. NSGs, UDRs, NAT, forced tunneling
5. Private endpoints & Private DNS
6. Identity & RBAC
7. Azure Policy governance
8. Azure CLI cheat codes
9. Common mistakes
10. Documentation links

---

## 1. Naming & tagging
- Pattern: `{type}-{project}-{env}-{region}-{instance}` (project = short per-project token, e.g. `dbx`), e.g. `vnet-dbx-prod-eastus2-001`.
  Respect Azure limits: Key Vault ≤24 chars; storage accounts ≤24, lowercase alphanumeric,
  globally unique (`stdbxprodeus2001`). Use CAF abbreviations for `{type}`.
- Tag **every** resource: `Environment`, `Owner`, `CostCenter`, `ManagedBy=terraform`,
  `Project`. Enforce with Azure Policy so untagged resources are denied.

## 2. Resource groups & subscriptions
- Group **by function** within an environment: `rg-networking-*`, `rg-databricks-*`,
  `rg-storage-*`, `rg-security-*`, `rg-shared-*`. RBAC then follows least privilege at the
  group boundary.
- Subscription boundary is the strongest isolation Azure offers — prod often gets its own.

## 3. Hub-spoke networking
- Hub VNet holds shared services (Private DNS zones always; Azure Firewall + hub NAT only
  when `deploy_firewall = true` — ADR-0007). Databricks **spoke** VNet holds the workload;
  it peers to the hub only in firewall mode (NAT-egress spokes stand alone).
- Spoke subnets for Databricks: two **delegated** subnets (`Microsoft.Databricks/workspaces`)
  + a separate **private-endpoint** subnet. VNet `/16`–`/24`; each Databricks subnet `/26`
  minimum (size `/24`–`/23` in prod — CIDR can't change after workspace deploy).

## 4. NSGs, UDRs, NAT — egress modes (ADR-0007)
- NSGs on subnets; Databricks auto-creates and protects its required rules (network intent
  policy) — don't override them. Extra rules are allowed but ONLY as standalone
  `azurerm_network_security_rule` resources (inline `security_rule` blocks make Terraform
  authoritative and delete the managed rules).
- Exactly ONE egress mode per spoke; either way clusters need an explicit egress path
  (Azure retired default outbound access for new subnets, Sept 2025):
  - **Firewall mode (prod/client posture):** UDR routes `0.0.0.0/0` from spoke subnets to
    the hub firewall's private IP, so all egress is inspected; hub NAT Gateway behind the
    firewall for the stable egress IP. The firewall **must allowlist** the required
    Databricks/Azure control-plane endpoints or clusters silently fail to launch.
  - **NAT mode (current dev default):** spoke-owned NAT Gateway on both delegated subnets
    (stable, auditable egress IP) + NSG outbound service-tag allowlist (AzureDatabricks,
    AzureActiveDirectory, Storage.\<region\>, Sql.\<region\>, EventHub.\<region\>) with a
    deny-Internet catch-all. No FQDN filtering — a service tag admits the whole regional
    service; documented dev-only trade-off.

## 5. Private endpoints & Private DNS
- For each PaaS service: create a **private endpoint**, **disable public network access**,
  and link the matching **Private DNS zone** to the VNet. Missing the DNS link is the
  classic "endpoint exists but cluster still resolves the public IP" failure.
- Zones used here:
  - ADLS Gen2: `privatelink.blob.core.windows.net`, `privatelink.dfs.core.windows.net`
  - Key Vault: `privatelink.vaultcore.azure.net`
  - Databricks: `privatelink.azuredatabricks.net`

## 6. Identity & RBAC
- **User-assigned managed identities by default** (survive Terraform recreate, shareable,
  grantable ahead of time, auditable). System-assigned only for tightly-bound 1:1 cases.
- RBAC = `principal × role × scope`. Scope nests MG → Sub → RG → resource and inherits
  **down**. Assign at the **narrowest** scope; prefer the **most specific built-in role**
  (e.g. `Storage Blob Data Contributor`, not `Contributor`/`Owner`).
- Assign to **Entra ID groups** mapped to job functions, not individuals.
- **Automation principals never get `Owner`** (it carries User Access Administrator =
  privilege escalation). Scope CI/CD principals per-subscription-per-environment.

## 7. Azure Policy governance
- Deploy guardrails **before** workloads: require tags, deny storage with public access,
  require NSGs on subnets, restrict allowed regions, enforce TLS minimums. Policy makes a
  module default (e.g. TLS 1.2) non-negotiable — defense in depth for configuration values.

## 8. Azure CLI cheat codes
```bash
az login                                            # interactive
az account set --subscription <SUB_ID>              # target subscription
az account show                                     # confirm context

# Resource groups
az group create -n rg-dbx-dev-eus2-001 -l eastus2

# User-assigned managed identity + role at narrow scope
az identity create -g rg-security-dbx-dev-eus2 -n id-connector-dbx-dev
az role assignment create \
  --assignee <identity-principal-id> \
  --role "Storage Blob Data Contributor" \
  --scope <storage-account-resource-id>

# OIDC federation: app + federated credential (no client secret)
az ad app create --display-name sp-dbx-cicd-prod
az ad sp create --id <app-id>
az ad app federated-credential create --id <app-id> --parameters '{
  "name": "github-prod",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:your-org/your-repo:environment:prod",
  "audiences": ["api://AzureADTokenExchange"]
}'

# Private DNS zone + link
az network private-dns zone create -g rg-networking-dbx-dev-eus2 \
  -n privatelink.blob.core.windows.net
az network private-dns link vnet create -g rg-networking-dbx-dev-eus2 \
  -z privatelink.blob.core.windows.net -n link-spoke \
  -v vnet-dbx-dev-eastus2-001 -e false

# Inspect role assignments at a scope
az role assignment list --scope <resource-id> -o table
```

## 9. Common mistakes
- Private endpoint created but Private DNS zone not linked → silent connection failure.
- Key Vault without purge protection / soft delete → unrecoverable secret loss.
- Over-broad RBAC at subscription/MG scope "to keep it simple" → blows least privilege.
- Under-sized Databricks subnets → IP exhaustion that needs a workspace rebuild to fix.
- Storage account names with hyphens/uppercase (invalid) or >24 chars.

## 10. Documentation links
- CAF resource naming: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
- CAF abbreviations: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
- Landing zones: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/
- Hub-spoke topology: https://learn.microsoft.com/en-us/azure/architecture/networking/architecture/hub-spoke
- Private endpoint DNS: https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
- Managed identities: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
- Azure built-in roles: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
- Azure Policy: https://learn.microsoft.com/en-us/azure/governance/policy/overview
- Key Vault security: https://learn.microsoft.com/en-us/azure/key-vault/general/security-features
