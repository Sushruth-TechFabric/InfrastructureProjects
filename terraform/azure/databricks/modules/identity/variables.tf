# =============================================================================
# modules/identity — INPUT VARIABLES (Databricks Access Connector + UAMI)
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group for the identity + access connector (e.g. rg-security-dbx-dev-eus2-001)."
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. eastus2)."
}

variable "user_assigned_identity_name" {
  type        = string
  description = "User-assigned managed identity name (e.g. id-connector-dbx-dev-eus2-001)."
}

variable "access_connector_name" {
  type        = string
  description = "Azure Databricks Access Connector name (e.g. dbac-dbx-dev-eus2-001)."
}

# NOTE: the Storage Blob Data Contributor role assignment that gives this identity
# secretless data access is intentionally NOT here. It lives in the environment
# root, where both the identity and the storage account are in scope, so this
# module stays a scope-agnostic blueprint (grant it against any storage later).

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
