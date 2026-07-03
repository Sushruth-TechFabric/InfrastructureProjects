# =============================================================================
# environments/dev-lab — REMOTE STATE BACKEND (Azure Storage, partial config)
# -----------------------------------------------------------------------------
# One state file per deployment boundary; this boundary's key is
# "environments/dev-lab/terraform.tfstate".
#
# The backend values are INTENTIONALLY NOT hardcoded here: every teammate
# deploys this lab into their OWN subscription, so each has their own backend
# storage account (its name is subscription-hashed by the bootstrap script).
#
# Setup (once, per person — full walkthrough in README.md):
#   1. ./scripts/bootstrap-tfstate.ps1 -Environment dev-lab -Location westus3
#   2. copy backend.hcl.example -> backend.hcl, paste the values the script printed
#      (backend.hcl is gitignored: it is per-person, not shared config)
#   3. terraform init "-backend-config=backend.hcl"
#      (keep the quotes — the command then works identically in every shell)
# =============================================================================

terraform {
  backend "azurerm" {}
}
