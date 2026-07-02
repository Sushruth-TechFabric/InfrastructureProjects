# =============================================================================
# environments/dev — REMOTE STATE BACKEND (Azure Storage)
# -----------------------------------------------------------------------------
# One state file per deployment boundary. This boundary's key is
# "environments/dev/terraform.tfstate".
#
# The backend storage account is created ONCE by scripts/bootstrap-tfstate.ps1
# (run with -Environment dev). Its name is subscription-hashed, so it is NOT
# statically known here. Either paste storage_account_name from the bootstrap
# output, or leave it blank and pass it at init:
#
#   terraform init \
#     -backend-config="resource_group_name=rg-tfstate-dev-wus3-001" \
#     -backend-config="storage_account_name=<from bootstrap>" \
#     -backend-config="container_name=tfstate" \
#     -backend-config="key=environments/dev/terraform.tfstate"
#
# use_azuread_auth = true -> data-plane auth via your Entra identity / CI OIDC.
# =============================================================================

terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-dev-wus3-001"
    storage_account_name = "sttfstatedevwus30016dc9" # from bootstrap-tfstate.ps1 -Environment dev
    container_name       = "tfstate"
    key                  = "environments/dev/terraform.tfstate"
    use_azuread_auth     = true
  }
}
