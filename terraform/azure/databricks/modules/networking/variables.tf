# =============================================================================
# modules/networking — INPUT VARIABLES
# -----------------------------------------------------------------------------
# A module is a *blueprint*: it declares WHAT it needs, never WHERE it runs.
# So there are NO defaults on environment-specific inputs — the caller (an
# environment root like environments/dev) must supply real values. That is what
# keeps one env's assumptions from leaking into shared code.
# =============================================================================

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the spoke VNet and its subnets (e.g. rg-networking-dev-eus2-001)."
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. eastus2)."
}

variable "vnet_name" {
  type        = string
  description = "Spoke virtual network name, per naming convention (e.g. vnet-dbx-dev-eus2-001)."
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Spoke VNet CIDR(s). Architecture rule: /16-/24 overall."

  validation {
    # Guard against a single obvious foot-gun: an empty address space.
    condition     = length(var.vnet_address_space) > 0
    error_message = "vnet_address_space must contain at least one CIDR block."
  }
}

variable "host_subnet_name" {
  type        = string
  description = "Databricks host (public) delegated subnet name (e.g. snet-dbx-host-dev)."
}

variable "host_subnet_prefix" {
  type        = string
  description = "CIDR for the host subnet. Databricks requires /26 minimum; /24-/23 in prod."
}

variable "container_subnet_name" {
  type        = string
  description = "Databricks container (private) delegated subnet name (e.g. snet-dbx-container-dev)."
}

variable "container_subnet_prefix" {
  type        = string
  description = "CIDR for the container subnet. Databricks requires /26 minimum; /24-/23 in prod."
}

variable "pe_subnet_name" {
  type        = string
  description = "Private-endpoint subnet name (separate from the delegated subnets, e.g. snet-dbx-pe-dev)."
}

variable "pe_subnet_prefix" {
  type        = string
  description = "CIDR for the private-endpoint subnet."
}

variable "firewall_private_ip" {
  type        = string
  description = <<-EOT
    Private IP of the hub Azure Firewall. Used as the next-hop for the forced-tunneling
    route (0.0.0.0/0). The env root resolves this from shared-services via an
    azurerm_firewall data source and passes it in — the module stays unaware of the hub.
  EOT
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
