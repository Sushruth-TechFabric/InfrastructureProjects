# =============================================================================
# environments/dev — INPUT VARIABLES
# -----------------------------------------------------------------------------
# Declared with type + description + validation where a real constraint exists.
# Concrete values live in terraform.tfvars (the only place env truth belongs).
# =============================================================================

variable "subscription_id" {
  type        = string
  description = "Target Azure subscription GUID for the dev environment."
}

variable "environment" {
  type        = string
  description = "Deployment environment token used in resource names."
  default     = "dev"

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "environment must be dev, qa, or prod."
  }
}

variable "location" {
  type        = string
  description = "Azure region long name (e.g. westus3)."
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

# ---- Cross-state (shared-services) lookup inputs ---------------------------
# These names must match what shared-services actually created — that is the
# naming-convention contract that lets us find hub resources by data source.

variable "hub_resource_group_name" {
  type        = string
  description = "Hub (shared-services) resource group name that holds the firewall, hub VNet, and DNS zones."
  default     = "rg-networking-shared-wus3-001"
}

variable "hub_vnet_name" {
  type        = string
  description = "Hub VNet name to peer the dev spoke with."
  default     = "vnet-hub-shared-wus3-001"
}

variable "hub_firewall_name" {
  type        = string
  description = "Hub Azure Firewall name; its private IP is the forced-tunneling next hop."
  default     = "afw-hub-shared-wus3-001"
}

# ---- Spoke network sizing --------------------------------------------------

variable "spoke_vnet_address_space" {
  type        = list(string)
  description = "Dev spoke VNet CIDR(s). /16-/24 overall."
  default     = ["10.10.0.0/20"]
}

variable "host_subnet_prefix" {
  type        = string
  description = "Host (public) delegated subnet CIDR. /26 min; /24 gives dev headroom."
  default     = "10.10.0.0/24"
}

variable "container_subnet_prefix" {
  type        = string
  description = "Container (private) delegated subnet CIDR."
  default     = "10.10.1.0/24"
}

variable "pe_subnet_prefix" {
  type        = string
  description = "Private-endpoint subnet CIDR."
  default     = "10.10.2.0/26"
}

# ---- Storage -----------------------------------------------------------------

variable "storage_account_name" {
  type        = string
  description = "ADLS Gen2 account name (globally unique, <=24 lowercase alnum, e.g. stdbxdevwus3001)."
  default     = "stdbxdevwus3001"
}

# ---- Workspace controls (databricks provider, pass 2) -----------------------

variable "allowed_ip_addresses" {
  type        = list(string)
  description = <<-EOT
    Workspace IP access list (ALLOW): public egress IPs/CIDRs permitted to reach
    the front-end (your home/VPN IP, CI egress ranges). Everything else is
    denied. NO DEFAULT on purpose — applying with a wrong list locks you out, so
    the value must be a conscious choice in terraform.tfvars. Find yours:
    `curl ifconfig.me`.
  EOT

  validation {
    condition     = length(var.allowed_ip_addresses) > 0
    error_message = "allowed_ip_addresses must contain at least one IP/CIDR, or you will lock yourself out of the workspace."
  }
}

variable "policy_node_types" {
  type        = list(string)
  description = "Approved node sizes users may pick in cluster policies (cost + capacity control)."
  default     = ["Standard_DS3_v2", "Standard_D4ads_v5"]
}

variable "policy_max_autotermination_minutes" {
  type        = number
  description = "Upper bound for cluster auto-termination; users can pick lower, never higher, never off."
  default     = 60
}

variable "policy_max_workers" {
  type        = number
  description = "Autoscale ceiling for jobs/shared cluster policies."
  default     = 4
}

# ---- RBAC (optional group grants) ------------------------------------------

variable "admin_group_object_ids" {
  type        = map(string)
  description = <<-EOT
    Optional map of "role => Entra ID group object id" to grant on the dev
    resource groups (RBAC to groups, never individuals). Empty by default so the
    build works before groups exist; fill in once the shared-services group sync
    has created them.
  EOT
  default     = {}
}

# ---- Tags -------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
