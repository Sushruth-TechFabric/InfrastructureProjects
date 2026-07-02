# =============================================================================
# shared-services — REMOTE STATE BACKEND (Azure Storage)
# -----------------------------------------------------------------------------
# One state file per deployment boundary. This boundary's key is
# "shared-services/terraform.tfstate".
#
# The backend storage account is created ONCE by scripts/bootstrap-tfstate.ps1
# (run it with -Environment shared). Its name is derived with a subscription-
# based hash, so it is NOT statically known here. Two ways to supply it:
#
#   (A) Fill storage_account_name below from the bootstrap script's output, OR
#   (B) leave it out and pass at init time (keeps the account name out of git):
#       terraform init -backend-config="resource_group_name=rg-tfstate-shared-wus3-001" \
#                      -backend-config="storage_account_name=<from bootstrap>" \
#                      -backend-config="container_name=tfstate" \
#                      -backend-config="key=shared-services/terraform.tfstate"
#
# use_azuread_auth = true -> data-plane auth via your Entra identity / CI OIDC.
# No storage account key is ever stored.
# =============================================================================

terraform {
  backend "azurerm" {
    resource_group_name = "rg-tfstate-shared-wus3-001"
    # TODO: run bootstrap-tfstate.ps1 -Environment shared -Location westus3 and paste
    # ITS output here. Do NOT reuse the dev account name (sttfstatedev...) — each
    # deployment boundary gets its own state account (one state file per boundary).
    storage_account_name = "sttfstatesharedwus306dc9"
    container_name       = "tfstate"
    key                  = "shared-services/terraform.tfstate"
    use_azuread_auth     = true
  }
}
