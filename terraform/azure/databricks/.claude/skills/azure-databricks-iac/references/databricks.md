# Azure Databricks — best practices, cheat codes, docs

## Table of contents
1. Two planes & SCC
2. VNet injection
3. Back-end Private Link & front-end (internet + identity-gated)
4. Egress allowlist
5. Storage hardening & secretless access
6. Unity Catalog
7. Key Vault & secrets
8. Cluster policies & workspace hardening
9. Databricks Terraform provider notes
10. Common mistakes
11. Documentation links

---

## 1. Two planes & SCC
- **Control plane** (UI, REST API, scheduler, cluster manager, SCC relay) = Microsoft-managed
  subscription. **Compute plane** (clusters) = your spoke VNet via VNet injection.
- **Secure Cluster Connectivity (SCC / No Public IP) — MUST.** Clusters have no public IP and
  no inbound ports. On startup each node opens an **outbound** tunnel up to the SCC relay; the
  control plane sends commands back down it (reverse tunnel). Access is outbound-initiated.

## 2. VNet injection
- Two **delegated** subnets (`Microsoft.Databricks/workspaces`): host + container. Plus a
  separate private-endpoint subnet. Don't share subnets across workspaces.
- Sizing: VNet `/16`–`/24`; each subnet `/26` minimum; `/24`–`/23` recommended in prod.
  **Subnet CIDR cannot change after deploy** — expansion needs a Databricks account-team
  request or a new workspace. Size for headroom up front.

## 3. Back-end Private Link & front-end (internet + identity-gated)
- **Back-end** (sub-resource `databricks_ui_api`): private path from clusters → control
  plane, on the workspace VNet's private-endpoint subnet, using zone
  `privatelink.azuredatabricks.net`. Region must match the workspace.
- **Front-end — this platform does NOT use front-end Private Link.** Users and tools
  (browser, CLI, Terraform, CI runners) reach the workspace **over the public internet**,
  authenticated by **Entra ID**. Workspace **public network access stays enabled** for the
  front-end. There is therefore **no transit subnet / user VNet path** and **no
  `browser_authentication` private endpoint**. (See the architecture doc's "Front-end
  access" decision — identity is the perimeter, and it keeps GitHub-hosted CI runners able
  to reach the REST API.)
- **Front-end hardening is MUST, because it is internet-reachable:**
  - **Workspace IP access lists** — allow only known egress ranges (corporate / VPN / CI),
    deny the rest.
  - **Entra ID Conditional Access** — MFA, device/compliance, ideally trusted-location.
- The **compute plane stays fully private** (SCC, no public IP, back-end Private Link) and
  **data + secrets stay private** (storage / Key Vault private endpoints, public access
  off). Internet exposure is limited to the authenticated front-end control surface only.

## 4. Egress allowlist
- With forced tunneling, the hub firewall must allow the required outbound endpoints
  (SCC relay, control plane, web app, metastore, artifact/log storage) per region, or
  clusters fail to start. Use the region-specific address list from Microsoft.

## 5. Storage hardening & secretless access
- ADLS Gen2: disable public access; private endpoints for `blob` + `dfs` with DNS zones;
  HTTPS-only, TLS 1.2 min; soft delete + versioning; optionally CMK in Key Vault.
- **Secretless compute→data auth:** Azure Databricks **Access Connector** carrying a
  **user-assigned managed identity**, granted **`Storage Blob Data Contributor`** on the
  storage. No account keys / SAS / SP secrets anywhere.

## 6. Unity Catalog
- Regional **metastore**; `catalog.schema.table` namespace.
- A **storage credential** wraps the Access Connector identity; an **external location**
  binds an ADLS path to that credential; access via SQL `GRANT` to **Entra ID groups**
  (never individuals); all access is audit-logged.

## 7. Key Vault & secrets
- Unavoidable secrets live in **Key Vault** (RBAC auth, private endpoint, purge protection,
  public access off). Notebooks read them via a **Key Vault-backed secret scope**
  (`dbutils.secrets.get(scope, key)`). Secrets never appear in notebook code.

## 8. Cluster policies & workspace hardening
- **Cluster policies** (JSON) are a *security* control: they force every cluster to inherit
  VNet injection + SCC, so a user can't create a cluster that bypasses the network. Lock:
  node types, autoscaling bounds, auto-termination, runtime version, data-access identity.
  Ship distinct policies (personal / jobs / shared).
- **Workspace hardening** (least functionality): restrict library install sources, control
  notebook export/download, govern Git integration, disable features that reopen a closed
  network path.

## 9. Databricks Terraform provider notes
- Two provider scopes: **account-level** (metastore, account groups, workspace assignment)
  and **workspace-level** (clusters, jobs, UC catalogs/schemas/grants, secret scopes,
  cluster policies). Configure each provider block explicitly.
- Authenticate the provider via Azure (managed identity / SP via OIDC), not PATs, in CI.
- Order matters: workspace + UC metastore exist before workspace-scoped resources; wire
  cross-resource references with provider aliases and `depends_on` where needed.
- Use the official Azure Private Link Terraform **guides** (linked below) as a reference
  implementation — they show the exact subnet delegation, private endpoint, and DNS wiring.

## 10. Common mistakes
- Under-sizing subnets (then needing a workspace rebuild).
- Back-end private endpoint without the DNS zone link → cluster can't reach the control plane.
- Disabling workspace public access on the front-end (this platform keeps it on, gated by
  Entra ID + IP access lists) → locks out users and GitHub-hosted CI runners.
- Skipping IP access lists / Conditional Access → the internet-reachable front-end is
  protected by credentials alone.
- Storing storage keys in a secret scope instead of using the Access Connector identity.
- Granting UC permissions to individuals instead of groups.
- No cluster policy → users create clusters that bypass the secured network.
- Forgetting the firewall egress allowlist → clusters hang/fail at launch.

## 11. Documentation links
- VNet injection: https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/vnet-inject
- Secure cluster connectivity: https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/secure-cluster-connectivity
- Private Link (concepts): https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/private-link
- Classic compute plane (back-end) Private Link: https://learn.microsoft.com/en-us/azure/databricks/security/network/classic/private-link-standard
- Workspace IP access lists: https://learn.microsoft.com/en-us/azure/databricks/security/network/front-end/ip-access-list
- Entra ID Conditional Access for Databricks: https://learn.microsoft.com/en-us/azure/databricks/security/auth/conditional-access
- Unity Catalog: https://learn.microsoft.com/en-us/azure/databricks/data-governance/unity-catalog/
- Access Connector / cloud storage: https://learn.microsoft.com/en-us/azure/databricks/connect/unity-catalog/cloud-storage/
- Cluster policies: https://learn.microsoft.com/en-us/azure/databricks/admin/clusters/policies
- Databricks Terraform provider: https://registry.terraform.io/providers/databricks/databricks/latest/docs
- TF provider Azure Private Link guides: https://registry.terraform.io/providers/databricks/databricks/latest/docs/guides
