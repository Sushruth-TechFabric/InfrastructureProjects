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
  description = "Resource group that holds the spoke VNet and its subnets (e.g. rg-networking-dbx-dev-eus2-001)."
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

# ---- Egress mode (exactly ONE of the two below — ADR-0007) ------------------

variable "firewall_private_ip" {
  type        = string
  default     = null
  description = <<-EOT
    EGRESS MODE A (firewall). Private IP of the hub Azure Firewall, used as the
    next-hop for the forced-tunneling route (0.0.0.0/0). The env root resolves
    this from shared-services via an azurerm_firewall data source and passes it
    in — the module stays unaware of the hub. Leave null when using NAT egress.
  EOT
}

variable "enable_nat_gateway_egress" {
  type        = bool
  default     = false
  description = <<-EOT
    EGRESS MODE B (NAT). Create a NAT Gateway on both delegated subnets plus an
    NSG outbound service-tag allowlist with a deny-Internet catch-all. The
    cost-optimized dev egress path (ADR-0007). Mutually exclusive with
    firewall_private_ip.
  EOT

  validation {
    # Exactly one egress mode: forced tunneling to a firewall, or NAT + NSGs.
    condition     = var.enable_nat_gateway_egress ? var.firewall_private_ip == null : var.firewall_private_ip != null
    error_message = "Choose exactly one egress mode: set firewall_private_ip (forced tunneling) OR enable_nat_gateway_egress = true (NAT + NSG allowlist), never both or neither."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
