# =============================================================================
# environments/dev — REMOTE STATE BACKEND (Azure Storage, partial config)
# -----------------------------------------------------------------------------
# One state file per deployment boundary; this boundary's key is
# "environments/dev/terraform.tfstate".
#
# The backend values are INTENTIONALLY NOT hardcoded here (E1 — hardcoded
# backend block removed, subscription-hashed name must stay uncommitted; from
# the uncommitted 2026-07-10 review): the storage account name is
# subscription-hashed by the bootstrap
# script, so it differs per subscription/deployer and must never be baked into
# a file every clone of this repo shares.
#
# Setup (once, per deployment boundary):
#   1. ./scripts/bootstrap-tfstate.ps1 -Environment dev -Location westus3
#   2. copy backend.hcl.example -> backend.hcl, paste the values the script
#      printed (backend.hcl is gitignored: it is per-deployment, not shared
#      config)
#   3. terraform init "-backend-config=backend.hcl"
#      (keep the quotes — PowerShell splits an unquoted -key=value arg on the
#      dot, so the command only works identically across shells when quoted)
#
# MIGRATING AN EXISTING DEPLOYMENT off the old hardcoded backend: this change
# does not move state. Run
#   terraform init "-backend-config=backend.hcl" -migrate-state
# once, with a backend.hcl that points at the SAME resource group / storage
# account / container / key the hardcoded block used to (see git history for
# the old values if you don't already have them recorded). Do not run this
# yourself as part of an unattended apply.
# =============================================================================

terraform {
  backend "azurerm" {}
}
