# =============================================================================
# shared-services — CONCRETE VALUES (this is where env-specific truth lives)
# -----------------------------------------------------------------------------
# Not secret: subscription id and CIDRs are safe to commit. Real secrets never
# go in tfvars — they come from Key Vault or an OIDC token at runtime.
# =============================================================================

subscription_id = "17a74f4d-a8f5-4955-9e38-9d222b8ea023" # TODO: set your hub/platform subscription GUID

location      = "westus3"
region_abbrev = "wus3"
instance      = "001"

hub_vnet_address_space = ["10.0.0.0/24"]
firewall_subnet_prefix = "10.0.0.0/26"

tags = {
  Environment = "shared"
  Owner       = "platform-team"
  CostCenter  = "cc-platform"
  ManagedBy   = "terraform"
  Project     = "azure-databricks-platform"
}
