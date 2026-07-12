# =============================================================================
# environments/staging — REMOTE STATE BACKEND (Azure Storage, partial config)
# -----------------------------------------------------------------------------
# One state file per deployment boundary; this boundary's key is
# "environments/staging/terraform.tfstate".
#
# Verbatim copy of the dev root's backend.tf pattern (E1/E7, 2026-07-10
# review) — only the key differs. See environments/dev/backend.tf for the full
# rationale.
#
# Setup (once, per deployment boundary):
#   1. ./scripts/bootstrap-tfstate.ps1 -Environment staging -Location westus3
#   2. copy backend.hcl.example -> backend.hcl, paste the values the script
#      printed (backend.hcl is gitignored: it is per-deployment, not shared
#      config)
#   3. terraform init "-backend-config=backend.hcl"
#      (keep the quotes — PowerShell splits an unquoted -key=value arg on the
#      dot, so the command only works identically across shells when quoted)
# =============================================================================

terraform {
  backend "azurerm" {}
}
