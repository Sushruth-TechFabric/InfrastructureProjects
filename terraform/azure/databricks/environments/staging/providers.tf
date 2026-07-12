# =============================================================================
# environments/dev — TERRAFORM + PROVIDER CONFIG
# -----------------------------------------------------------------------------
# Three providers, three scopes:
#   - azurerm             -> the Azure infra layer (pass 1)
#   - databricks          -> WORKSPACE-scoped controls (pass 2: cluster
#                            policies, secret scope)
#   - databricks.account  -> ACCOUNT-scoped: identity (ADR-0008: group shells +
#                            workspace permission assignments), UC metastore
#                            lookup/assignment (ADR-0011, uc.tf), and the
#                            serverless Network Connectivity Config (ADR-0012,
#                            network-connectivity.tf), via accounts.azuredatabricks.net
#   - azuread             -> Entra ID groups (the identity source of truth)
#   - azapi               -> approve the inbound serverless-plane private endpoint
#                            connections Databricks raises on our ADLS / Key Vault
#                            (ADR-0012); azurerm has no resource for owner-side
#                            approval of a third-party-initiated connection
# All of them authenticate through Azure (your `az login` locally / OIDC in
# CI) — no PATs, no stored secrets. The UC metastore itself is managed in
# shared-services (ADR-0011); this root attaches it and owns the per-env
# storage credential / external location in uc.tf.
# =============================================================================

terraform {
  required_version = ">= 1.9, < 2.0" # verified against local Terraform v1.15.7

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.121"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {
    # Let `terraform destroy` remove the Key Vault even with purge protection on.
    # Driven by var.kv_purge_on_destroy (default false); dev's tfvars opts in as
    # a dev convenience. Leave false in staging/prod.
    key_vault {
      purge_soft_delete_on_destroy = var.kv_purge_on_destroy
    }
  }

  subscription_id = var.subscription_id
}

# Workspace-scoped databricks provider. Pointing it at the azurerm-managed
# workspace resource id lets it exchange your Azure credential for a Databricks
# token automatically. NOTE the ordering consequence: this provider can only
# authenticate once the workspace EXISTS — on a fresh
# subscription run a two-phase apply:
#   terraform apply "-target=module.databricks_workspace"   # infra first
#   terraform apply                                          # then workspace controls
# (keep the quotes around -target args — portable across shells)
provider "databricks" {
  azure_workspace_resource_id = module.databricks_workspace.workspace_id
}

# ACCOUNT-level databricks provider (ADR-0008) — talks to the account console
# API, not a workspace. The deploying identity must be a Databricks ACCOUNT
# admin (a workspace admin gets "Principal not found in account" errors).
# auth_type is PINNED so a missing/wrong credential fails fast with a named
# method instead of the SDK silently probing PATs/env vars in an opaque order:
# "azure-cli" locally (default), "github-oidc-azure" in CI via TF_VAR_.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = var.databricks_account_auth_type
}

# Entra ID (Microsoft Graph). Tenant comes from az login locally / ARM_* OIDC
# env in CI — nothing to configure here.
provider "azuread" {}

# azapi — used only to approve the inbound private endpoint connections the
# Databricks serverless plane raises on our ADLS / Key Vault (ADR-0012). Rides
# the same Azure auth as azurerm (az login locally / OIDC in CI) — nothing to
# configure. v2 takes HCL bodies (not jsonencode).
provider "azapi" {}
