# =============================================================================
# modules/databricks-workspace — INPUT VARIABLES
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the workspace resource (e.g. rg-databricks-dev-eus2-001)."
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. eastus2)."
}

variable "workspace_name" {
  type        = string
  description = "Databricks workspace name (e.g. dbw-dbx-dev-eus2-001)."
}

variable "managed_resource_group_name" {
  type        = string
  description = "Name for the Databricks-managed resource group it creates (e.g. rg-dbw-managed-dev-eus2-001)."
}

variable "virtual_network_id" {
  type        = string
  description = "Resource ID of the spoke VNet the workspace is injected into."
}

variable "host_subnet_name" {
  type        = string
  description = "Name of the delegated host (public) subnet."
}

variable "container_subnet_name" {
  type        = string
  description = "Name of the delegated container (private) subnet."
}

variable "host_subnet_nsg_association_id" {
  type        = string
  description = <<-EOT
    ID of the host subnet's NSG association. Passed in so the workspace waits for
    the NSG to be attached before it validates the injected network (avoids a
    race where Databricks checks the subnet before its NSG exists).
  EOT
}

variable "container_subnet_nsg_association_id" {
  type        = string
  description = "ID of the container subnet's NSG association (same race-avoidance reason)."
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource."
}
