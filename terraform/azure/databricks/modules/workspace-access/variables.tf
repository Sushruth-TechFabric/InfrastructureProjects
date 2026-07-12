# =============================================================================
# modules/workspace-access — INPUT VARIABLES
# =============================================================================

variable "project" {
  type        = string
  description = "Short project/workload token used in group display names (e.g. dbx)."
}

variable "environment" {
  type        = string
  description = "Deployment environment token used in group display names (e.g. dev)."
}

variable "workspace_id" {
  type        = number
  description = <<-EOT
    NUMERIC Databricks workspace id (azurerm_databricks_workspace.workspace_id
    attribute / the databricks-workspace module's `workspace_resource_id`
    output) — NOT the Azure resource ID.
  EOT
}

variable "group_owners" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Entra object ids to add as ADDITIONAL group owners, alongside the applying
    identity (data.azuread_client_config.current.object_id, always included).
    Pass the CI OIDC service principal's object id here so ownership is stable
    across human `az login` applies and CI applies — without this, whichever
    identity applied most recently is the sole owner and every switch between
    human/CI applies churns ownership (each apply revokes the other's owner
    grant). Optional: defaults to an empty list, so the deployer remains the
    only owner until a caller opts in.
  EOT
}

variable "groups" {
  type = map(object({
    role_token           = string
    members              = list(string)
    workspace_permission = string
  }))
  description = <<-EOT
    Workspace access groups. The map KEY is a stable logical handle used for
    Terraform addressing — it must NEVER change once applied (renaming a key
    destroys/recreates the group, minting a new Databricks-internal principal
    id that cascades into the workspace assignment and any future UC grants;
    see ADR-0008). Rename the DISPLAY NAME via role_token instead — that
    updates in place.

    role_token           -> display name is derived, not free-form:
                            grp-{project}-{environment}-{role_token}
    members              -> Entra UPNs of EXISTING users. User lifecycle is out
                            of scope; an unknown UPN fails the plan loudly.
                            Membership is AUTHORITATIVE: anyone added by hand
                            in the Entra portal is removed on the next apply.
    workspace_permission -> "ADMIN" or "USER" (workspace admins vs users).
  EOT

  validation {
    condition = alltrue([
      for g in var.groups : contains(["ADMIN", "USER"], g.workspace_permission)
    ])
    error_message = "workspace_permission must be exactly \"ADMIN\" or \"USER\"."
  }

  validation {
    condition = length(distinct([
      for g in var.groups : g.role_token
    ])) == length(var.groups)
    error_message = "role_token values must be unique — duplicate tokens would derive the same group display name."
  }
}
