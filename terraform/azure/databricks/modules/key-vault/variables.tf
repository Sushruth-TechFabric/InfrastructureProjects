# =============================================================================
# modules/key-vault — INPUT VARIABLES
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group for the Key Vault (e.g. rg-security-dev-eus2-001)."
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. eastus2)."
}

variable "key_vault_name" {
  type        = string
  description = "Key Vault name, <=24 chars, globally unique (e.g. kv-dbx-dev-eus2-001)."

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,24}$", var.key_vault_name))
    error_message = "key_vault_name must be 3-24 chars, alphanumeric and hyphens only."
  }
}

variable "tenant_id" {
  type        = string
  description = "Entra ID tenant GUID that owns the vault's RBAC/authentication."
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Days a soft-deleted vault/secret is recoverable (7-90)."
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
