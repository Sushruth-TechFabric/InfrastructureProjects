---
name: azure-databricks-lookup
description: >-
  Fast reference lookups for this Azure Databricks Terraform/GitHub Actions platform:
  command syntax, naming/tagging conventions, provider pinning format, and
  documentation links. Use for quick questions like "what's the command for X",
  "what's the naming convention for Y", or "where are the docs for Z" that don't
  involve writing, editing, or reviewing infrastructure code. If the task turns into
  authoring or reviewing .tf files or Azure/Databricks resources, use
  azure-databricks-author-review instead — it carries the security guardrails this
  skill intentionally omits.
---

# Azure Databricks Platform — Quick Lookup

Reference-only, inline, no guardrails. Answer directly from the matching file below
and stop.

- Terraform commands, state, modules, variables, pinning →
  [references/terraform.md](../azure-databricks-author-review/references/terraform.md)
- Azure resources: naming/tagging, networking, RBAC, Key Vault, storage, DNS →
  [references/azure.md](../azure-databricks-author-review/references/azure.md)
- Databricks workspace, VNet injection, Unity Catalog, cluster policies, provider notes →
  [references/databricks.md](../azure-databricks-author-review/references/databricks.md)
- GitHub Actions, OIDC, approval gates, skeleton workflows →
  [references/github-actions.md](../azure-databricks-author-review/references/github-actions.md)

If the question turns out to require writing, editing, or reviewing actual
infrastructure code — not just looking something up — stop and use
`azure-databricks-author-review` instead. That skill enforces this platform's Golden
rules and pre-flight checklist; this one deliberately does not.
