# =============================================================================
# environments/dev — TERRAFORM + PROVIDER CONFIG
# -----------------------------------------------------------------------------
# Two providers, two scopes:
#   - azurerm    -> the Azure infra layer (pass 1)
#   - databricks -> WORKSPACE-scoped controls (pass 2: IP access list, cluster
#                   policies, secret scope). Authenticates through Azure (your
#                   `az login` locally / OIDC in CI) against the workspace the
#                   azurerm provider created — no PATs, no stored secrets.
# Unity Catalog for this env still waits on the shared-services account-level
# metastore (ADR-0001/0002); nothing here is account-scoped.
# =============================================================================

terraform {
  required_version = ">= 1.9, < 2.0" # verified against local Terraform v1.15.7

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
  }
}

provider "azurerm" {
  features {
    # Let `terraform destroy` remove the Key Vault even with purge protection on
    # (dev convenience). In prod you would leave this false.
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }

  subscription_id = var.subscription_id
}

# Workspace-scoped databricks provider. Pointing it at the azurerm-managed
# workspace resource id lets it exchange your Azure credential for a Databricks
# token automatically. NOTE the ordering consequence: this provider can only
# authenticate once the workspace EXISTS and your IP can reach it — on a fresh
# subscription run a two-phase apply:
#   terraform apply "-target=module.databricks_workspace"   # infra first
#   terraform apply                                          # then workspace controls
# (keep the quotes around -target args — portable across shells)
provider "databricks" {
  azure_workspace_resource_id = module.databricks_workspace.workspace_id
}
