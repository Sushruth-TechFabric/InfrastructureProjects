# =============================================================================
# modules/storage — ADLS GEN2 DATA LAKE (hardened, private-only by default)
# -----------------------------------------------------------------------------
# ADLS Gen2 = a StorageV2 account with Hierarchical Namespace (HNS) enabled.
# Security posture (all MUSTs from the architecture doc):
#   - public network access OFF by default -> reachable only via private endpoint
#   - HTTPS only + TLS 1.2 min
#   - blob versioning + soft delete (recover from bad writes / deletes)
#   - default network action Deny (belt-and-suspenders with public access off)
# The private endpoint + Private DNS zone that make this account reachable are
# created in the ENVIRONMENT ROOT, because they depend on the spoke subnet and
# the shared-services DNS zones (cross-state glue, not a reusable blueprint).
#
# ADR-0006: lab profiles may flip public_network_access_enabled to true — even
# then the firewall stays default-Deny with an explicit IP allowlist plus a
# resource-instance rule for the Databricks Access Connector. Secure roots pass
# none of the network vars and keep the exact posture above.
# =============================================================================

resource "azurerm_storage_account" "adls" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = var.account_replication_type
  account_kind             = "StorageV2"
  is_hns_enabled           = true # <- this is what makes it ADLS Gen2 (Data Lake), not plain blob.

  # ---- Network hardening -------------------------------------------------
  public_network_access_enabled   = var.public_network_access_enabled # false unless a lab profile overrides (ADR-0006)
  https_traffic_only_enabled      = true                              # reject plain HTTP
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false # no anonymous blob/container access
  shared_access_key_enabled       = var.shared_access_key_enabled

  # Default-deny firewall. With public access off this is redundant belt-and-
  # suspenders; with public access on (lab) it is the control that makes
  # "public" mean "reachable through an allowlist", not "open".
  network_rules {
    default_action = var.network_default_action
    bypass         = ["AzureServices"]
    ip_rules       = var.network_ip_rules

    # Resource-instance rules: admit specific Azure resources (by identity, not
    # IP) through the firewall — e.g. the Databricks Access Connector, whose
    # compute traffic has no allowlistable IP in the lab's managed VNet.
    dynamic "private_link_access" {
      for_each = var.network_resource_access_ids

      content {
        endpoint_resource_id = private_link_access.value
      }
    }
  }

  # ---- Data protection ---------------------------------------------------
  # NOTE: blob VERSIONING is NOT supported on accounts with hierarchical
  # namespace (is_hns_enabled = true) — Azure rejects the combination. Soft
  # delete IS supported on HNS. For point-in-time recovery on a data lake, use
  # Delta Lake time travel (table-level history) instead of blob versioning.
  blob_properties {
    delete_retention_policy {
      days = var.soft_delete_retention_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# ADLS Gen2 filesystems. In ADLS Gen2 a filesystem IS a blob container, so we
# create them as azurerm_storage_container with storage_account_id — that form
# is managed via the MANAGEMENT plane (ARM), which the storage firewall does not
# gate. The dedicated azurerm_storage_data_lake_gen2_filesystem resource uses the
# DATA plane (…dfs.core.windows.net) and 403s when public network access is off
# and the caller (your laptop / CI) is outside the VNet — the classic
# private-storage chicken-and-egg. Management plane avoids it entirely.
#
# for_each over a set so adding/removing a name never shifts an index and churns
# unrelated filesystems (the count trap).
# ---------------------------------------------------------------------------
resource "azurerm_storage_container" "this" {
  for_each              = toset(var.filesystem_names)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.adls.id
  container_access_type = "private"
}
