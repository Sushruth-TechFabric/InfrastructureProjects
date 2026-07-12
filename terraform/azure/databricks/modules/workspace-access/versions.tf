# =============================================================================
# modules/workspace-access — PROVIDER REQUIREMENTS
# -----------------------------------------------------------------------------
# This module spans two identity planes:
#   - azuread    -> Entra ID groups (the source of truth)
#   - databricks -> the ACCOUNT-level API (accounts.azuredatabricks.net), NOT a
#                   workspace host. The root must pass its account-scoped
#                   provider explicitly:
#                     providers = { databricks.account = databricks.account }
# `configuration_aliases` makes that contract explicit — a root that forgets to
# pass the account provider fails at init, not with a confusing 401 at plan.
# =============================================================================

terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.121"
      configuration_aliases = [databricks.account]
    }
  }
}
