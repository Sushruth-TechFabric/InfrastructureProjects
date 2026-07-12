---
name: azure-databricks-author-review
description: >-
  Golden rules, guardrails, and pre-flight checklist for AUTHORING or REVIEWING
  production-grade Infrastructure-as-Code for a secure Azure Databricks platform
  (Terraform + GitHub Actions). Use WHENEVER the task involves creating, editing, or
  reviewing Terraform (.tf/.tfvars), Azure resources (networking, RBAC, Key Vault,
  storage, private endpoints), Azure Databricks (workspace, VNet injection, Unity
  Catalog, cluster policies, Access Connector), or GitHub Actions workflows for infra
  deployment — even if the user does not explicitly say "best practices". Trigger on
  mentions of azurerm, databricks provider, remote state, OIDC, VNet injection,
  private link, managed identity, cluster policy, or any *.tf authoring/review. Runs
  as an isolated Sonnet sub-review so guardrails are enforced consistently regardless
  of the session's model. For quick command/syntax/naming-convention/doc-link lookups
  with no authoring or review involved, use azure-databricks-lookup instead — it's
  cheaper and doesn't fork.
context: fork
model: sonnet
agent: general-purpose
---

# Azure Databricks Platform — Author & Review

You are authoring or reviewing Infrastructure-as-Code for this secure Azure
Databricks platform. The full architecture decisions live in
`docs/architecture/azure-platform-architecture.md` (the project's source of truth) —
read it if the task touches networking, identity, or Unity Catalog topology. This
skill is the *operational* layer: how to write or review the code without violating
those decisions, plus per-tool command cheatsheets and doc links.

## Task

$ARGUMENTS

## How to work

1. Read the **Golden rules** below — they apply to every infra change.
2. Load only the reference file(s) relevant to the task:
   - Writing/refactoring Terraform, state, modules, variables → `references/terraform.md`
   - Azure resources: networking, RBAC, Key Vault, storage, DNS, policy → `references/azure.md`
   - Databricks workspace, VNet injection, Unity Catalog, cluster policies → `references/databricks.md`
   - CI/CD pipelines, OIDC auth, approval gates → `references/github-actions.md`
3. Make the change (or produce the review), then run the **Pre-flight checklist**
   before reporting done.

## Golden rules (apply always — MUST)

1. **No secrets in tracked files.** Never write keys, passwords, connection strings,
   client secrets, or SAS tokens into `.tf`, `.tfvars`, workflow YAML, or this repo.
   If a value is sensitive, it comes from Key Vault or an OIDC token at runtime.
2. **Modules hold no environment values.** A module is a blueprint; environment-specific
   values live in each environment's `terraform.tfvars`. Required inputs get no default.
3. **One state file per deployment boundary.** `environments/<env>` and `shared-services`
   each own their state. Never let a change in one cross into another.
4. **Cross-state dependencies use Azure data sources by name** (e.g. `azurerm_subnet`),
   never `terraform_remote_state`, never hardcoded resource IDs. Naming conventions are
   the contract that makes this work.
5. **Pin everything.** Modules via `?ref=vX.Y.Z` (git tag), providers via
   `required_providers`, Terraform via `required_version`; commit `.terraform.lock.hcl`.
   Pin third-party GitHub Actions to a **commit SHA**, not a mutable tag.
6. **Default-deny networking.** Disable public access; use private endpoints + linked
   Private DNS zones for every PaaS service. Forgetting the DNS link is the classic
   silent failure.
7. **Databricks compute/data planes stay sealed; front-end is identity-gated.** SCC on
   (no public IP), VNet injection, **back-end Private Link** for the compute plane. The
   **front-end stays internet-reachable** (workspace public access enabled), gated by
   **Entra ID + Conditional Access** — no front-end Private Link, no user VNet path, no
   workspace IP access lists (ADR-0010). Data and secret planes stay fully private.
   Cluster policies force every cluster to inherit the secured network.
8. **Identity over secrets.** User-assigned managed identities by default; data access
   via Access Connector identity + `Storage Blob Data Contributor` (no keys). CI/CD via
   OIDC federated credential scoped to repo+branch. Never grant `Owner` to automation.
9. **Plan is reviewed, not the version number.** Generate a plan for the target
   environment; humans approve the diff. `apply` runs only in CI after merge, never from
   a laptop against shared environments.
10. **Least privilege RBAC.** Narrowest scope, most specific built-in role, assign to
    Entra ID groups not individuals.

## Pre-flight checklist (run before reporting any change as done)

- [ ] `terraform fmt` clean and `terraform validate` passes.
- [ ] No secret or environment-specific value baked into a module or committed file.
- [ ] Cross-resource references resolved via data sources / named lookups, not hardcoded IDs.
- [ ] New PaaS resource: public access disabled + private endpoint + private DNS zone linked.
- [ ] New identity: user-assigned MI, scoped role at the narrowest scope, granted to a group.
- [ ] Module/provider versions pinned; lock file committed.
- [ ] A `terraform plan` for the target environment was produced and reviewed.
- [ ] If it conflicts with a Golden rule or the architecture doc, surface the conflict
      instead of silently complying.

## When the user is wrong or a request is risky

If a request would weaken a security posture (open public access, store a secret, widen a
role, apply to prod without review), do not silently comply. State which rule it touches,
explain the risk in one or two sentences, and offer the compliant alternative.

## Tooling quick reference

- Format/validate: `terraform fmt -recursive`, `terraform validate`
- Lint: **TFLint** (`tflint`) — provider-specific best practices and deprecated args.
- Security scan: **Trivy** (`trivy config .`) and/or **Checkov** (`checkov -d .`).
  Note: `tfsec` is deprecated (merged into Trivy); Terrascan is archived — do not add them.
- Docs: **terraform-docs** generates module input/output tables.
- Wire all of the above as **pre-commit** hooks so failures shift left.

See the reference files for full command cheatsheets and the documentation index.
