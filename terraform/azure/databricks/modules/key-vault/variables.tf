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

# ---- Network exposure (ADR-0006) --------------------------------------------
# Secure defaults: private-endpoint-only. Only lab profiles override these, and
# even then "public" means reachable through a default-deny firewall with an
# explicit allowlist. Secure roots pass nothing and their plans stay identical.

variable "public_network_access_enabled" {
  type        = bool
  description = "Expose a public endpoint. Keep false (private-endpoint-only) outside lab profiles (ADR-0006)."
  default     = false # secure default — existing roots unaffected
}

variable "network_default_action" {
  type        = string
  description = "Vault firewall default action when the public endpoint is enabled."
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be \"Allow\" or \"Deny\"."
  }
}

variable "network_ip_rules" {
  type        = list(string)
  description = <<-EOT
    Public IPs/CIDRs allowed through the vault firewall (only meaningful when
    public_network_access_enabled = true). Pass bare IPs (e.g. "203.0.113.10")
    or CIDR ranges; Key Vault normalizes /32 suffixes away, so bare IPs avoid
    perpetual plan diffs.
  EOT
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
