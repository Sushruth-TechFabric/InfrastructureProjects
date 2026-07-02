# =============================================================================
# modules/key-vault — OUTPUTS
# =============================================================================

output "key_vault_id" {
  description = "Resource ID of the Key Vault (RBAC scope + private endpoint target)."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Vault URI (e.g. for a Key Vault-backed secret scope later)."
  value       = azurerm_key_vault.this.vault_uri
}
