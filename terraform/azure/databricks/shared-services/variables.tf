# =============================================================================
# shared-services — INPUT VARIABLES
# -----------------------------------------------------------------------------
# This is a ROOT config (deploy-once hub), so unlike a module it CAN carry
# sensible defaults; the concrete values live in terraform.tfvars.
# =============================================================================

variable "subscription_id" {
  type        = string
  description = "Target Azure subscription GUID for the shared-services (hub) deployment."
}

variable "location" {
  type        = string
  description = "Azure region long name for the hub (e.g. westus3)."
  default     = "westus3"
}

variable "region_abbrev" {
  type        = string
  description = "Short region token used in resource names (e.g. wus3)."
  default     = "wus3"
}

variable "instance" {
  type        = string
  description = "Zero-padded instance number for names."
  default     = "001"
}

variable "hub_vnet_address_space" {
  type        = list(string)
  description = "Hub VNet CIDR(s)."
  default     = ["10.0.0.0/24"]
}

variable "firewall_subnet_prefix" {
  type        = string
  description = "CIDR for AzureFirewallSubnet (name is fixed by Azure; must be /26 or larger)."
  default     = "10.0.0.0/26"
}

variable "spoke_vnet_names" {
  type        = list(string)
  description = <<-EOT
    Names of spoke VNets whose resources must resolve the Private DNS zones.
    The zone->VNet links for spokes are created in each env root (the env owns its
    VNet); this list is only used if you later choose to centralize links here.
  EOT
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
