# =============================================================================
# environments/dev — CONCRETE VALUES (the only place dev's truth lives)
# -----------------------------------------------------------------------------
# Safe to commit: subscription id, CIDRs, names. Real secrets never go here.
# =============================================================================

subscription_id = "17a74f4d-a8f5-4955-9e38-9d222b8ea023" # TODO: set your dev subscription GUID

environment   = "dev"
location      = "westus3"
region_abbrev = "wus3"
instance      = "001"

# ---- Hub (shared-services) lookups — must match what shared-services created --
hub_resource_group_name = "rg-networking-shared-wus3-001"
hub_vnet_name           = "vnet-hub-shared-wus3-001"
hub_firewall_name       = "afw-hub-shared-wus3-001"

# ---- Spoke network sizing ---------------------------------------------------
spoke_vnet_address_space = ["10.10.0.0/20"]
host_subnet_prefix       = "10.10.0.0/24"
container_subnet_prefix  = "10.10.1.0/24"
pe_subnet_prefix         = "10.10.2.0/26"

# ---- Storage (globally unique; change if the name is taken) -----------------
storage_account_name = "stdbxdevwus3001"

# ---- Workspace controls (pass 2) ---------------------------------------------
# IP access list: MUST include your current egress IP (`curl ifconfig.me`) or you
# lock yourself out of the workspace front-end. Add VPN/CI ranges as needed.
allowed_ip_addresses = ["72.214.215.146"] # TODO: replace with YOUR egress IP before apply

# Cluster-policy tuning (defaults are fine for dev; shown here for visibility)
policy_node_types                  = ["Standard_DS3_v2", "Standard_D4ads_v5"]
policy_max_autotermination_minutes = 60
policy_max_workers                 = 4

# ---- RBAC groups (empty until shared-services group sync creates them) -------
admin_group_object_ids = {}

# ---- Tags (required set on every resource) ----------------------------------
tags = {
  Environment = "dev"
  Owner       = "data-platform-team"
  CostCenter  = "cc-dev-1001"
  ManagedBy   = "terraform"
  Project     = "azure-databricks-platform"
}
