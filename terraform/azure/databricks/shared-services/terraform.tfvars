# =============================================================================
# shared-services — CONCRETE VALUES (this is where env-specific truth lives)
# -----------------------------------------------------------------------------
# Not secret: subscription id and CIDRs are safe to commit. Real secrets never
# go in tfvars — they come from Key Vault or an OIDC token at runtime.
# =============================================================================

subscription_id = "17a74f4d-a8f5-4955-9e38-9d222b8ea023" # TODO: set your hub/platform subscription GUID

project       = "dbx" # short token embedded in every resource name — spokes must match
location      = "westus3"
region_abbrev = "wus3"
instance      = "001"

hub_vnet_address_space = ["10.0.0.0/24"]
firewall_subnet_prefix = "10.0.0.0/26"

# ADR-0007: firewall chain OFF — dev egresses via its own NAT Gateway + NSG
# allowlist. Flip to true (and rewire the spoke roots to firewall mode) to
# restore the enterprise forced-tunneling reference. Meter warning: true costs
# ~$1.25/hr firewall + NAT + IPs from the moment of apply.
deploy_firewall = false

# ADR-0011: account id for the UC metastore's account-level provider. An
# identifier, not a secret — same value as environments/dev/terraform.tfvars
# (found at accounts.azuredatabricks.net; deployer must be an ACCOUNT admin).
databricks_account_id = "00000000-0000-0000-0000-000000000000" # TODO: set your Databricks account GUID

# ADR-0011 follow-up, resolved: metastore owner is a platform-admin ACCOUNT
# GROUP, never the applying individual (rule 10). grp-dbx-dev-admins is the
# ADMIN-permission group environments/dev's workspace-access module
# materializes at the account level (databricks_group) — referenced here BY
# NAME, the same cross-state-by-name contract ADR-0011 extends to Databricks
# account objects (never terraform_remote_state). No platform-wide (non-env)
# admin group exists yet; swap this for one if/when it's created.
#
# BOOTSTRAP ORDER CAVEAT: this metastore is created in shared-services (deploy
# step 2), BEFORE environments/dev (step 4) ever creates grp-dbx-dev-admins —
# on a brand-new subscription the very first shared-services apply will 400 on
# a nonexistent owner principal. Leave this commented out (or null) for that
# first apply, run environments/dev pass 2 so the group exists, then uncomment
# and re-apply shared-services. Every apply after that is a normal in-place
# update.
metastore_owner = "grp-dbx-dev-admins"

tags = {
  Environment = "shared"
  Owner       = "platform-team"
  CostCenter  = "cc-platform"
  ManagedBy   = "terraform"
  Project     = "azure-databricks-platform"
}
