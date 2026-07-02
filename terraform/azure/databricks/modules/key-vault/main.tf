# =============================================================================
# modules/key-vault — PRIVATE, RBAC-AUTHORIZED KEY VAULT
# -----------------------------------------------------------------------------
# Secrets that CAN'T be replaced by a managed identity live here. Posture:
#   - RBAC authorization (not legacy access policies) -> permissions are Azure
#     role assignments, reviewable/auditable like every other RBAC grant
#   - purge protection ON -> a deleted vault/secret can't be permanently wiped
#     within the retention window (prevents unrecoverable secret loss)
#   - public network access OFF + default-deny ACL -> reachable only via its
#     private endpoint (created in the environment root)
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

  # Network: private-only. Public access off; default-deny for defense in depth.
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = var.tags
}
