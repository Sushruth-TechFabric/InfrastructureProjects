# =============================================================================
# modules/storage — INPUT VARIABLES (ADLS Gen2 data lake)
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group for the storage account (e.g. rg-storage-dev-eus2-001)."
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

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
