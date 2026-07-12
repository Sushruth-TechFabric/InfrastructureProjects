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

variable "project" {
  type        = string
  description = <<-EOT
    Short project/workload token used in every resource name (the {project}
    slot of the naming convention). Spoke roots look hub resources up BY NAME,
    so they must use the same value.
  EOT
  default     = "dbx"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project))
    error_message = "project must be 2-8 lowercase letters/digits (it is embedded in length-limited Azure names)."
  }
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

variable "deploy_firewall" {
  type        = bool
  default     = false
  description = <<-EOT
    Deploy the Azure Firewall chain (firewall + policy + egress allowlist + NAT
    Gateway + public IPs, ~$920/mo idle). Default false per ADR-0007: spokes
    egress via their own NAT Gateway + NSG allowlist instead. Set true to
    restore the enterprise forced-tunneling reference — and switch the spoke
    roots back to firewall mode (firewall_private_ip + VNet peering) to match.
  EOT
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

# ---- Unity Catalog metastore (ADR-0011) --------------------------------------

variable "databricks_account_id" {
  type        = string
  description = <<-EOT
    Databricks ACCOUNT id (the GUID shown at accounts.azuredatabricks.net).
    An identifier, not a secret — safe in tfvars. Used only by the
    account-level provider for the UC metastore.
  EOT

  validation {
    condition     = can(regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", lower(var.databricks_account_id)))
    error_message = "databricks_account_id must be a GUID (find it at accounts.azuredatabricks.net)."
  }
}

variable "databricks_account_auth_type" {
  type        = string
  description = <<-EOT
    Auth method for the ACCOUNT-level databricks provider, pinned so a bad
    credential fails fast instead of the SDK probing methods silently.
    "azure-cli" = ride `az login` (local default). CI overrides to
    "github-oidc-azure" via TF_VAR_databricks_account_auth_type.
  EOT
  default     = "azure-cli"

  validation {
    condition     = contains(["azure-cli", "github-oidc-azure", "azure-msi"], var.databricks_account_auth_type)
    error_message = "databricks_account_auth_type must be azure-cli, github-oidc-azure, or azure-msi (secretless methods only — no PATs, no client secrets)."
  }
}

variable "metastore_owner" {
  type        = string
  description = <<-EOT
    Owner of the UC metastore — an account GROUP name (rule 10: groups, not
    individuals), never a user. Default null = Terraform does not manage the
    owner: the creating principal on create, the existing owner on import.
    terraform.tfvars sets this to grp-dbx-dev-admins (ADR-0011 follow-up,
    resolved) — the only account-level admin group that currently exists,
    materialized by environments/dev's workspace-access module. Swap for a
    platform-wide admin group if/when one is created that isn't scoped to a
    single environment. See the BOOTSTRAP ORDER CAVEAT comment in
    terraform.tfvars before changing this on a not-yet-deployed subscription:
    shared-services applies BEFORE environments/dev creates the group, so a
    non-null value here on the very first-ever apply fails on a nonexistent
    principal.
  EOT
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
