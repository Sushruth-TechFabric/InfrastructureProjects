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
  }
}

provider "azurerm" {
  # azurerm 4.x requires an explicit subscription. We take it from a variable so
  # the value lives in tfvars, not in provider code. (Auth itself comes from az
  # login locally or the OIDC federated credential in CI — never a stored secret.)
  features {}

  subscription_id = var.subscription_id
}
