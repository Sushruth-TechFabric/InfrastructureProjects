# =============================================================================
# modules/key-vault — PRIVATE, RBAC-AUTHORIZED KEY VAULT
# -----------------------------------------------------------------------------
# Secrets that CAN'T be replaced by a managed identity live here. Posture:
#   - RBAC authorization (not legacy access policies) -> permissions are Azure
#     role assignments, reviewable/auditable like every other RBAC grant
#   - purge protection ON -> a deleted vault/secret can't be permanently wiped
#     within the retention window (prevents unrecoverable secret loss)
#   - public network access OFF by default + default-deny ACL -> reachable only
#     via its private endpoint (created in the environment root). ADR-0006 lab
#     profiles may enable the public endpoint, still default-deny + IP allowlist.
# Notebooks read these secrets through a Key Vault-backed secret scope, so the
# secret value never appears in code. (The secret scope is a databricks-provider
# resource, added in a later pass.)
# =============================================================================

resource "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # Authorize with Azure RBAC instead of vault access policies.
  rbac_authorization_enabled = true

  # Recoverability: soft delete is always on; purge protection blocks a hard
  # delete within the retention window. Required by the architecture doc.
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  # Network: private-only by default (public access off; default-deny for
  # defense in depth). Lab profiles flip public access on but keep default-deny
  # plus an IP allowlist (ADR-0006).
  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    default_action = var.network_default_action
    bypass         = "AzureServices"
    ip_rules       = var.network_ip_rules
  }

  tags = var.tags
}
