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
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
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
# In NAT-egress mode (ADR-0007) the only hub dependency is the DNS zones; the
# hub VNet / firewall name variables return with the firewall mode.

variable "hub_resource_group_name" {
  type        = string
  description = <<-EOT
    Hub (shared-services) resource group name that holds the Private DNS zones.
    Must match what shared-services derives from its own project/region/instance
    inputs. Leave null to derive it from THIS root's own project/region/instance
    inputs via the naming convention (rg-networking-{project}-shared-{region_abbrev}-{instance})
    — the current default for every existing deployment. Override only if the
    hub was deployed with different project/region/instance tokens than this
    spoke.
  EOT
  default     = null
}

variable "metastore_name" {
  type        = string
  description = <<-EOT
    UC metastore name (shared-services, ADR-0011), resolved by data source —
    the by-name cross-state contract extended to Databricks account objects.
    Must match what shared-services derives from its own project/region/instance
    inputs. Leave null to derive it from THIS root's own project/region/instance
    inputs via the naming convention (mst-{project}-shared-{region_abbrev}-{instance})
    — the current default for every existing deployment. Override only if the
    metastore was deployed with different project/region/instance tokens than
    this spoke.
  EOT
  default     = null
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
  description = <<-EOT
    ADLS Gen2 account name (globally unique, <=24 lowercase alnum; convention
    st{project}{env}{region}{instance}, e.g. stdbxdevwus3001). Leave null to
    derive it from project/environment/region_abbrev/instance via the naming
    convention — the current default for every existing deployment. Override
    only if the derived name is already taken globally.
  EOT
  default     = null
}

# ---- Workspace controls (databricks provider, pass 2) -----------------------

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

# ---- Identity / workspace access (ADR-0008) ---------------------------------

variable "databricks_account_id" {
  type        = string
  description = <<-EOT
    Databricks ACCOUNT id (the GUID shown at accounts.azuredatabricks.net).
    An identifier, not a secret — safe in tfvars. Used only by the
    account-level provider for the identity layer.
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

variable "identity_groups" {
  type = map(object({
    role_token           = string
    members              = list(string)
    workspace_permission = string
  }))
  description = <<-EOT
    Workspace access groups for THIS environment (shape documented in
    modules/workspace-access). Map keys are immutable logical handles;
    role_token derives the display name (grp-{project}-{env}-{role_token}); members
    are Entra UPNs (authoritative — a PR here is the only way in);
    workspace_permission is ADMIN or USER.
  EOT

  validation {
    condition     = contains(keys(var.identity_groups), "admins")
    error_message = "identity_groups must include an \"admins\" key — uc.tf's local.uc_owner pins every UC object's owner to it (rule 10: groups, not individuals)."
  }
}

# ---- Workspace-object permissions (ADR-0009) --------------------------------

variable "cluster_policy_can_use" {
  type        = map(list(string))
  description = <<-EOT
    Which identity groups may use each cluster policy: policy key
    (personal | jobs | shared — the fixed set defined in workspace-config.tf)
    => list of identity_groups keys granted CAN_USE. Grants go to GROUPS only,
    never individuals (AGENTS.md rule 10). Workspace admins always have
    implicit access and never take an entry here. An absent policy key or an
    empty list means "admins only" for that policy. AUTHORITATIVE per policy:
    grants made in the UI but not listed here are removed on the next apply.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for policy_key, _ in var.cluster_policy_can_use :
      contains(["personal", "jobs", "shared"], policy_key)
    ])
    error_message = "cluster_policy_can_use keys must be a subset of {personal, jobs, shared} — the policies defined in workspace-config.tf."
  }

  validation {
    condition = alltrue([
      for _, group_keys in var.cluster_policy_can_use : alltrue([
        for g in group_keys : contains(keys(var.identity_groups), g)
      ])
    ])
    error_message = "Every group referenced in cluster_policy_can_use must be a key of identity_groups (use the logical key, e.g. \"users\", not the display name)."
  }
}

variable "secret_scope_read_groups" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted READ on the Key Vault-backed secret scope
    (kv-{project}-{env}) — i.e. who may dbutils.secrets.get() from it. READ is
    the only meaningful non-admin ACL on a KV-backed scope (writes go to Key
    Vault, not through Databricks); workspace admins manage implicitly. Empty
    list = admins only.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.secret_scope_read_groups : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every entry of secret_scope_read_groups must be a key of identity_groups."
  }
}

# ---- RBAC (optional group grants) ------------------------------------------

variable "key_vault_secrets_officer_groups" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted Key Vault Secrets Officer on the environment
    Key Vault — i.e. who may create/update the secret values that the KV-backed
    scope exposes. Officer covers secrets only (not keys/certificates/vault
    config). Notebook READS go through the AzureDatabricks first-party service
    principal (granted Secrets User in main.tf), so consumer groups do NOT
    belong here. Empty list = no Terraform-managed identity can write secrets.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.key_vault_secrets_officer_groups : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every entry of key_vault_secrets_officer_groups must be a key of identity_groups."
  }
}

variable "resource_group_reader_groups" {
  type        = list(string)
  description = <<-EOT
    identity_groups keys granted Reader on the four dev resource groups —
    Azure-plane portal/CLI visibility for humans (ADR-0008's deferred RBAC
    seam). Reader only: all writes go through Terraform; wider roles would
    invite the portal drift this repo forbids. Empty list = no human
    Azure-plane access.
  EOT
  default     = []

  validation {
    condition = alltrue([
      for g in var.resource_group_reader_groups : contains(keys(var.identity_groups), g)
    ])
    error_message = "Every entry of resource_group_reader_groups must be a key of identity_groups."
  }
}

# ---- Tags -------------------------------------------------------------------

variable "tags" {
  type        = map(string)
  description = "Common tags applied to every resource (Environment, Owner, CostCenter, ManagedBy, Project)."
}
