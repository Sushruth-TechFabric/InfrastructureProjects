# =============================================================================
# modules/storage — INPUT VARIABLES (ADLS Gen2 data lake)
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group for the storage account (e.g. rg-storage-dbx-dev-eus2-001)."
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. eastus2)."
}

variable "storage_account_name" {
  type        = string
  description = "Globally-unique storage account name, lowercase alphanumeric, <=24 chars (e.g. stdbxdeveus2001)."

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 chars, lowercase letters and digits only."
  }
}

variable "filesystem_names" {
  type        = list(string)
  description = "ADLS Gen2 filesystem (container) names to create, e.g. [\"bronze\", \"silver\", \"gold\"]."
  default     = ["data"]
}

variable "soft_delete_retention_days" {
  type        = number
  description = "Days to retain soft-deleted blobs (state/data recovery window)."
  default     = 7
}

variable "account_replication_type" {
  type        = string
  description = "Storage account redundancy (LRS/ZRS/GRS/RAGRS/GZRS/RAGZRS). Default LRS is a dev/lab-appropriate cost choice — revisit for prod resilience requirements."
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.account_replication_type)
    error_message = "account_replication_type must be one of LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "shared_access_key_enabled" {
  type        = bool
  description = <<-EOT
    Enable storage account key / SAS authentication. Keep false: all sanctioned
    access is identity-based (Access Connector user-assigned managed identity +
    Unity Catalog, golden rule 7), so nothing needs account keys, and keys-on
    lets any principal with listKeys bypass Entra RBAC and UC entirely. Only
    flip true with a stated, ADR-recorded reason.
  EOT
  default     = false
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
  description = "Storage firewall default action when the public endpoint is enabled."
  default     = "Deny"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be \"Allow\" or \"Deny\"."
  }
}

variable "network_ip_rules" {
  type        = list(string)
  description = <<-EOT
    Public IPs/CIDRs allowed through the storage firewall (only meaningful when
    public_network_access_enabled = true). Azure rejects /31 and /32 CIDRs —
    pass bare IPs (e.g. "203.0.113.10") or ranges /30 and larger.
  EOT
  default     = []
}

variable "network_resource_access_ids" {
  type        = list(string)
  description = <<-EOT
    Azure resource IDs granted a resource-instance rule through the storage
    firewall (e.g. a Databricks Access Connector). Required in the lab profile:
    without VNet injection, cluster/serverless traffic arrives from Databricks
    managed-VNet IPs that can never be allowlisted, so Unity Catalog access is
    admitted per RESOURCE INSTANCE (the Access Connector identity) instead of
    per IP. Empty in secure roots (traffic uses private endpoints).
  EOT
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
