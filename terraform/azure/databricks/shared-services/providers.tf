# =============================================================================
# shared-services — TERRAFORM + PROVIDER CONFIG
# -----------------------------------------------------------------------------
# Pin everything (rule #5): Terraform core, providers, and (committed alongside)
# the .terraform.lock.hcl so every machine/CI run resolves identical versions.
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
      version = "~> 1.121"
    }
  }
}

provider "azurerm" {
  # azurerm 4.x requires an explicit subscription. We take it from a variable so
  # the value lives in tfvars, not in provider code. (Auth itself comes from az
  # login locally or the OIDC federated credential in CI — never a stored secret.)
  features {}

  subscription_id = var.subscription_id
}

# ACCOUNT-level databricks provider (ADR-0011) — talks to the account console
# API, not a workspace; used only for the UC metastore in uc.tf. The deploying
# identity must be a Databricks ACCOUNT admin (same prerequisite as dev's
# identity layer, ADR-0008). auth_type is PINNED so a missing/wrong credential
# fails fast with a named method instead of the SDK silently probing PATs/env
# vars in an opaque order: "azure-cli" locally (default), "github-oidc-azure"
# in CI via TF_VAR_.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = var.databricks_account_auth_type
}
