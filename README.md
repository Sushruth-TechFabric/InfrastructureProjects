# InfrastructureProjects

Infrastructure-as-Code monorepo, organized by tool → cloud → platform:

```
terraform/
  azure/
    databricks/   # Secure Azure Databricks platform (active) — see its README/AGENTS.md
  aws/
    databricks/   # Placeholder — not started
  gcp/
    databricks/   # Placeholder — not started
```

Each leaf project is self-contained: its own modules, environments, remote
state, docs, and agent instructions (`AGENTS.md` / `CLAUDE.md`). Start with
[`terraform/azure/databricks`](terraform/azure/databricks/), the only active
project. Its deploy runbook lives at
[`terraform/azure/databricks/docs/runbooks/deploy-dev.md`](terraform/azure/databricks/docs/runbooks/deploy-dev.md).
