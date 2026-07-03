# =============================================================================
# environments/dev-lab — TERRAFORM + PROVIDER CONFIG (ADR-0006)
# -----------------------------------------------------------------------------
# Cost-optimized personal lab: always-AVAILABLE workspace, strictly on-demand
# compute, ~$3-5/month idle. This is a deliberate, documented downgrade from the
# secure enterprise posture (see docs/design/dev-lab-profile.md); the secure
# environments/dev root remains the architectural reference.
#
# Two providers, two scopes:
#   - azurerm    -> the Azure infra layer (workspace, storage, KV, identity, budget)
#   - databricks -> WORKSPACE-scoped controls (IP access list, cluster policy,
#                   cluster, warehouse, Unity Catalog objects). Authenticates
#                   through Azure (`az login`) against the workspace this root
#                   creates — no PATs, no stored secrets.
#
# ORDERING (read before first apply — full steps in this folder's README.md):
# databricks-provider resources need the workspace to EXIST and your IP to be
# able to reach it. On a fresh subscription run a two-phase apply:
#   terraform apply "-target=azurerm_databricks_workspace.this"   # infra first
#   terraform apply                                               # then the rest
# (keep the quotes around -target/-backend-config args — portable across shells)
# =============================================================================

terraform {
  required_version = ">= 1.9, < 2.0"

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
    # Deploy/destroy cycles are a lab norm, so make destroy + re-apply smooth:
    key_vault {
      # Try to purge on destroy. Purge protection (module-enforced) blocks the
      # purge itself, so the vault soft-deletes instead...
      purge_soft_delete_on_destroy = true
      # ...and a re-apply within the retention window then RECOVERS the
      # soft-deleted vault instead of failing on a name collision.
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      # Azure occasionally drops hidden, non-Terraform resources into RGs;
      # don't let that wedge `terraform destroy` in a throwaway lab.
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

# Workspace-scoped databricks provider: exchanges your Azure credential
# (az login) for a Databricks token against the workspace created below.
provider "databricks" {
  azure_workspace_resource_id = azurerm_databricks_workspace.this.id
}
