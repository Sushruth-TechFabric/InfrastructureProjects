# =============================================================================
# modules/identity — SECRETLESS DATA ACCESS (Access Connector + UAMI)
# -----------------------------------------------------------------------------
# "Access is something you ARE, not something you HOLD."
#
# The Azure Databricks Access Connector is a first-party resource that lets the
# Databricks compute plane assume an Azure managed identity. We attach a
# USER-ASSIGNED managed identity (UAMI) to it. When Databricks reads ADLS, it
# authenticates AS that identity — no account keys, SAS tokens, or SP secrets
# stored anywhere.
#
# Why user-assigned (not system-assigned)? A user-assigned identity is a
# standalone resource: it survives destroy/recreate of the connector, keeps a
# STABLE principal id (so its role assignment doesn't churn and re-propagate),
# can be granted access ahead of time, and is auditable on its own.
#
# The role assignment (Storage Blob Data Contributor) is done in the env root.
# =============================================================================

resource "azurerm_user_assigned_identity" "connector" {
  name                = var.user_assigned_identity_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_databricks_access_connector" "this" {
  name                = var.access_connector_name
  location            = var.location
  resource_group_name = var.resource_group_name

  # Bind the user-assigned identity to the connector. Databricks (via Unity
  # Catalog storage credentials, added later) will act as this identity.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.connector.id]
  }

  tags = var.tags
}
