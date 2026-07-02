# =============================================================================
# modules/storage — ADLS GEN2 DATA LAKE (hardened, private-only)
# -----------------------------------------------------------------------------
# ADLS Gen2 = a StorageV2 account with Hierarchical Namespace (HNS) enabled.
# Security posture (all MUSTs from the architecture doc):
#   - public network access OFF  -> reachable only via private endpoint
#   - HTTPS only + TLS 1.2 min
#   - blob versioning + soft delete (recover from bad writes / deletes)
#   - default network action Deny (belt-and-suspenders with public access off)
# The private endpoint + Private DNS zone that make this account reachable are
# created in the ENVIRONMENT ROOT, because they depend on the spoke subnet and
# the shared-services DNS zones (cross-state glue, not a reusable blueprint).
# =============================================================================

resource "azurerm_storage_account" "adls" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS" # dev: local redundancy. Prod would revisit (ZRS/GZRS) — see resilience deferral.
  account_kind             = "StorageV2"
  is_hns_enabled           = true # <- this is what makes it ADLS Gen2 (Data Lake), not plain blob.

  # ---- Network hardening -------------------------------------------------
  public_network_access_enabled   = false # no public endpoint at all
  https_traffic_only_enabled      = true  # reject plain HTTP
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false # no anonymous blob/container access
  shared_access_key_enabled       = true  # kept on for now; UC access is identity-based, not keys

  # Default-deny firewall. With public access already off this is redundant, but
  # it makes intent explicit and survives a future flip of public access.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
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
