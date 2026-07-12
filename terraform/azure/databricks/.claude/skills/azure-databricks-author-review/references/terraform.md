# Terraform — best practices, cheat codes, docs

## Table of contents
1. Structure & state
2. Variables & tfvars
3. Modules & versioning
4. Provider & version pinning
5. Cross-state dependencies
6. Command cheat codes
7. Refactoring safely (moved/import/-replace)
8. Quality gates (fmt/validate/lint/scan/docs)
9. Drift detection
10. Common mistakes
11. Documentation links

---

## 1. Structure & state
- `modules/` = reusable blueprints (no env values). `environments/{dev,staging,prod}/` and
  `shared-services/` = root configs, **each with its own state file**.
- Backend is Azure Storage with **blob-lease locking** (no extra infra needed):
  ```hcl
  terraform {
    backend "azurerm" {
      resource_group_name  = "rg-tfstate-prod-eus2-001"
      storage_account_name = "sttfstateprodeus2001"
      container_name       = "tfstate"
      key                  = "environments/prod/terraform.tfstate"
    }
  }
  ```
- Harden the state storage account: **RBAC first** (only platform team + CI/CD principal,
  via `Storage Blob Data Contributor` at container scope), then no public access + private
  endpoint, soft delete + versioning, TLS-only, and a `CanNotDelete` lock.
- If a run dies mid-apply and leaves a stale lease: `terraform force-unlock <LOCK_ID>`.
- **Do not** use CLI workspaces as the dev/staging/prod boundary — weak isolation (one
  `workspace select` mistake = wrong env). Use separate root configs + state keys.

## 2. Variables & tfvars
- Every variable: declare `type`, add a `description`, add `validation` where there are
  real constraints, and mark secret-bearing ones `sensitive = true`.
  ```hcl
  variable "environment" {
    type        = string
    description = "Deployment environment."
    validation {
      condition     = contains(["dev", "staging", "prod"], var.environment)
      error_message = "environment must be dev, staging, or prod."
    }
  }
  ```
- **Value location reflects meaning:** universal truth → module `default`; per-environment
  truth → `terraform.tfvars`; secret/ephemeral → `TF_VAR_*` env var or Key Vault at runtime.
- `main.tf` should look nearly identical across environments (it just calls modules); the
  intentional differences live in each env's `tfvars`.

## 3. Modules & versioning
- Reference shared modules by **pinned git tag**, not a local path, so each env upgrades
  on its own schedule:
  ```hcl
  module "networking" {
    source = "git::https://github.com/your-org/terraform-modules.git//networking?ref=v1.3.0"
  }
  ```
- Use **semantic versioning** as a compatibility contract: PATCH = safe fix, MINOR =
  backward-compatible addition, MAJOR = breaking (renamed/removed/required input). A
  breaking change in a non-MAJOR bump destroys the trust model — never do it.
- Start with git tags; graduate to a private registry only when module discoverability
  becomes a real problem.

## 4. Provider & version pinning
```hcl
terraform {
  required_version = "~> 1.9"
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 4.0" }
    databricks = { source = "databricks/databricks", version = "~> 1.121" }
  }
}
```
- Commit **`.terraform.lock.hcl`** so every machine/CI run resolves identical provider
  versions. For multi-OS CI, generate cross-platform hashes:
  `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`.

## 5. Cross-state dependencies
- Resolve by **Azure data source + naming convention**, never `terraform_remote_state`,
  never hardcoded IDs:
  ```hcl
  data "azurerm_subnet" "dbx_host" {
    name                 = "snet-dbx-host-${var.environment}"
    virtual_network_name = "vnet-dbx-${var.environment}-${var.region}-001"
    resource_group_name  = "rg-networking-${var.environment}-${var.region}"
  }
  ```
- This requires the dependency to exist first → enforce deploy ordering
  (shared-services → networking → security → workloads).

## 6. Command cheat codes
```bash
terraform init                       # init backend + providers
terraform init -upgrade              # re-resolve provider versions within constraints
terraform fmt -recursive             # auto-format
terraform validate                   # syntax + internal consistency
terraform plan -out=tfplan           # SAVE the plan (review THIS, apply THIS)
terraform apply tfplan               # apply the exact reviewed plan
terraform plan -refresh-only         # detect drift without proposing config changes
terraform output                     # show outputs
terraform output -raw <name>         # raw value (e.g. to pipe)
terraform console                    # interactive expression evaluation
terraform state list                 # list resources in state
terraform state show <addr>          # inspect one resource
terraform state mv <src> <dst>       # rename/move in state (prefer 'moved' blocks)
terraform state rm <addr>            # forget a resource (does NOT destroy it)
terraform import <addr> <id>         # bring an existing Azure resource under management
terraform apply -replace=<addr>      # force recreate (replaces deprecated 'taint')
terraform force-unlock <LOCK_ID>     # clear a stale state lock
```

## 7. Refactoring safely
- Renaming/moving resources: prefer a **`moved` block** in code (reviewable, versioned)
  over `terraform state mv`:
  ```hcl
  moved {
    from = azurerm_subnet.dbx
    to   = azurerm_subnet.dbx_host
  }
  ```
- Adopting existing infra: `import` blocks (declarative) or `terraform import` (CLI).
- Forcing recreation: `-replace=<addr>` (not the old `taint`).

## 8. Quality gates
- `terraform fmt -check` and `terraform validate` (cheap, always).
- **TFLint** — provider-specific rules, deprecated args, naming. Configure the azurerm
  ruleset plugin.
- **Trivy** (`trivy config .`) and/or **Checkov** (`checkov -d .`) for security
  misconfigurations (public storage, missing encryption, over-broad roles). tfsec is
  deprecated → use Trivy; Terrascan is archived.
- **terraform-docs** to auto-generate module input/output documentation.
- Wire these into **pre-commit** so problems are caught before PR.

## 9. Drift detection
- `terraform plan` is your drift detector: a non-empty plan on unchanged code = drift
  (someone changed Azure outside Terraform). `-refresh-only` isolates pure drift.
- Run a scheduled CI plan to catch drift proactively; treat unexpected diffs as incidents.

## 10. Common mistakes
- Environment values as module defaults (bakes one env's assumptions into shared code).
- Secrets in tfvars committed to git (the #1 IaC credential leak).
- Editing state by hand or `state rm` without understanding it orphans resources.
- Unpinned providers → "works on my machine," different plan next week.
- `count` for keyed collections (index shifts cause churn) — prefer `for_each` with a map.

## 11. Documentation links
- Terraform language & style: https://developer.hashicorp.com/terraform/language/style
- Modules: https://developer.hashicorp.com/terraform/language/modules
- azurerm backend: https://developer.hashicorp.com/terraform/language/backend/azurerm
- azurerm provider docs: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
- databricks provider docs: https://registry.terraform.io/providers/databricks/databricks/latest/docs
- moved/import/refactoring: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
- TFLint: https://github.com/terraform-linters/tflint
- Trivy (IaC scanning): https://trivy.dev/  · repo: https://github.com/aquasecurity/trivy
- Checkov: https://www.checkov.io/
- terraform-docs: https://terraform-docs.io/
- pre-commit-terraform: https://github.com/antonbabenko/pre-commit-terraform
