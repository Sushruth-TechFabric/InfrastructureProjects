# =============================================================================
# environments/dev-lab — INPUT VARIABLES
# -----------------------------------------------------------------------------
# Per-person values live in terraform.tfvars (gitignored for this root — every
# teammate deploys to their OWN subscription). Start from terraform.tfvars.example.
# =============================================================================

variable "subscription_id" {
  type        = string
  description = "YOUR Azure subscription GUID (the lab deploys entirely into it)."
}

variable "project" {
  type        = string
  description = <<-EOT
    Short project/workload token used in every resource name (the {project}
    slot of the naming convention). Keep it 2-8 lowercase alphanumerics —
    Key Vault (<=24 chars) and storage-account (<=24, alnum only) names are
    the binding length constraints.
  EOT
  default     = "dbx"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.project))
    error_message = "project must be 2-8 lowercase letters/digits (it is embedded in length-limited Azure names)."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment token used in resource names."
  default     = "lab"

  validation {
    condition     = var.environment == "lab"
    error_message = "This root is the dev-lab profile; environment must stay \"lab\" (names/state assume it)."
  }
}

variable "location" {
  type        = string
  description = "Azure region long name. Pick one with Databricks serverless + Foundation Model APIs (e.g. westus3, eastus2)."
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

# ---- Storage -----------------------------------------------------------------

variable "storage_account_name" {
  type        = string
  description = "ADLS Gen2 account name — GLOBALLY unique across Azure, so every teammate must pick their own (convention st{project}lab<initials>{region}, e.g. stdbxlab<initials>wus3)."

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 chars, lowercase letters and digits only."
  }
}

# ---- Storage/Key Vault firewall allowlist ------------------------------------

variable "allowed_ip_addresses" {
  type        = list(string)
  description = <<-EOT
    Public egress IPs/CIDRs allowed through the storage/Key Vault firewalls
    (your home/VPN IP). Everything else is denied. (The workspace front-end is
    NOT gated by IP — Entra ID only, per ADR-0010.) NO DEFAULT on purpose —
    applying with a wrong list locks you out of storage/Key Vault, so the value
    must be a conscious choice in terraform.tfvars. Find yours:
    `curl ifconfig.me`. Prefer a small CIDR range (e.g. x.y.z.0/24) over a
    single IP so an ISP address rotation doesn't lock you out; Azure Storage
    rejects /31 and /32 — use bare IPs or /30 and larger.
  EOT

  validation {
    condition     = length(var.allowed_ip_addresses) > 0
    error_message = "allowed_ip_addresses must contain at least one IP/CIDR, or you will lock yourself out of storage and Key Vault."
  }
}

# ---- Compute (strictly on-demand — this is what keeps the lab ~$3-5 idle) ----

variable "cluster_node_type" {
  type        = string
  description = "VM size for the single-node practice cluster (small on purpose)."
  default     = "Standard_DS3_v2"
}

variable "autotermination_minutes" {
  type        = number
  description = "Idle minutes before the practice cluster terminates. The cluster policy FIXES this value so it cannot be raised or disabled in the UI."
  default     = 20

  validation {
    condition     = var.autotermination_minutes >= 10 && var.autotermination_minutes <= 60
    error_message = "autotermination_minutes must be between 10 and 60 — never 0 (0 = never terminate = runaway spend)."
  }
}

variable "enable_serverless" {
  type        = bool
  description = "Create the serverless SQL warehouse. Set false if your Databricks account/region lacks serverless (a classic PRO warehouse with the same auto-stop is created instead)."
  default     = true
}

variable "warehouse_auto_stop_mins" {
  type        = number
  description = "Idle minutes before the SQL warehouse auto-stops."
  default     = 10

  validation {
    condition     = var.warehouse_auto_stop_mins >= 5
    error_message = "warehouse_auto_stop_mins must be >= 5 (and never 0 = always on)."
  }
}

# ---- Budget guardrail ---------------------------------------------------------

variable "budget_amount" {
  type        = number
  description = "Monthly subscription budget in USD; notifications fire at 50/80/100% actual + 100% forecasted."
  default     = 150
}

variable "budget_contact_emails" {
  type        = list(string)
  description = "Email recipients for budget notifications (your inbox)."

  validation {
    condition     = length(var.budget_contact_emails) > 0
    error_message = "budget_contact_emails must contain at least one address — a silent budget is no guardrail."
  }
}

# ---- Tags ----------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
