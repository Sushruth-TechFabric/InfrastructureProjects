# =============================================================================
# environments/dev — CONCRETE VALUES (the only place dev's truth lives)
# -----------------------------------------------------------------------------
# Safe to commit: subscription id, CIDRs, names. Real secrets never go here.
# =============================================================================

subscription_id = "17a74f4d-a8f5-4955-9e38-9d222b8ea023" # TODO: set your dev subscription GUID

project       = "dbx" # short token embedded in every resource name — change per project
environment   = "dev"
location      = "westus3"
region_abbrev = "wus3"
instance      = "001"

# dev convenience; leave false in staging/prod
kv_purge_on_destroy = true

# ---- Hub (shared-services) lookups — must match what shared-services created --
# NAT-egress mode (ADR-0007): only the DNS-zone resource group is needed.
hub_resource_group_name = "rg-networking-dbx-shared-wus3-001"

# ---- Spoke network sizing ---------------------------------------------------
spoke_vnet_address_space = ["10.10.0.0/20"]
host_subnet_prefix       = "10.10.0.0/24"
container_subnet_prefix  = "10.10.1.0/24"
pe_subnet_prefix         = "10.10.2.0/26"

# ---- Storage (globally unique; change if the name is taken) -----------------
storage_account_name = "stdbxdevwus3001"

# ---- Workspace controls (pass 2) ---------------------------------------------
# Cluster-policy tuning (defaults are fine for dev; shown here for visibility)
policy_node_types                  = ["Standard_DS3_v2", "Standard_D4ads_v5"]
policy_max_autotermination_minutes = 60
policy_max_workers                 = 4

# ---- Identity / workspace access (ADR-0008) ----------------------------------
# Account id is at accounts.azuredatabricks.net (an identifier, not a secret).
# Prerequisite: Automatic Identity Management ENABLED on the account
# (Security -> User provisioning) and the deployer is an ACCOUNT admin.
databricks_account_id = "00000000-0000-0000-0000-000000000000" # TODO: set your Databricks account GUID

# Map keys are immutable handles (never rename them — ADR-0008); rename the
# display name via role_token instead. Membership is authoritative: this list
# IS the group; portal additions are reverted on the next apply.
identity_groups = {
  admins = {
    role_token           = "admins"
    members              = ["sushruth.aeluguri@techfabric.com"]
    workspace_permission = "ADMIN"
  }
  users = {
    role_token           = "users"
    members              = []
    workspace_permission = "USER"
  }
  # Data engineers: write on bronze/silver, read on gold (see schema_grants).
  engineers = {
    role_token           = "engineers"
    members              = [] # TODO: add data-engineer UPNs
    workspace_permission = "USER"
  }
  # BI / SQL consumers: read-only on gold, and only gold (see schema_grants).
  bi_users = {
    role_token           = "bi_users"
    members              = [] # TODO: add BI/SQL-user UPNs
    workspace_permission = "USER"
  }
}

# ---- Workspace-object permissions (grants to identity_groups keys, ADR-0009) -
# Admins are OMITTED on purpose: workspace admins implicitly manage policies
# and scopes; explicit entries would be redundant. The jobs policy is
# intentionally absent = admins-only — job clusters are created by automation
# principals in prod, and dev mirrors that posture. AUTHORITATIVE for cluster
# policies: UI-added grants not listed here are reverted on the next apply.
cluster_policy_can_use = {
  personal = ["users"]
  shared   = ["users"]
}

secret_scope_read_groups = ["users"]

# Who may WRITE secret values into the vault (reads ride the AzureDatabricks
# first-party SP grant in main.tf — consumer groups never go here).
key_vault_secrets_officer_groups = ["admins"]

# ---- Azure-plane RBAC (Reader on the four RGs, to identity_groups keys) ------
resource_group_reader_groups = ["admins"]

# ---- Unity Catalog: catalogs / schemas as config (add/remove by re-applying) -
# One catalog whose managed storage is the `catalog` container; each medallion
# schema binds to its own container (bronze/silver/gold) for physical storage
# isolation — a 1:1 map to the filesystems module.storage provisions.
catalogs = {
  dbx_dev = {
    comment           = "Dev lakehouse catalog"
    storage_container = "catalog"
    schemas = {
      bronze = { comment = "Raw / landing layer", storage_container = "bronze" }
      silver = { comment = "Cleaned / conformed layer", storage_container = "silver" }
      gold   = { comment = "Curated / BI-ready layer", storage_container = "gold" }
    }
  }
}

# ---- UC grants (to identity_groups keys — GROUPS only, never individuals) ----
# Admins are OMITTED on purpose: workspace/account admins have implicit UC
# admin privileges; an explicit grant would be redundant.
catalog_grants = {
  dbx_dev = {
    engineers = ["USE_CATALOG"]
    bi_users  = ["USE_CATALOG"]
  }
}

schema_grants = {
  "dbx_dev.bronze" = { engineers = ["USE_SCHEMA", "SELECT", "MODIFY", "CREATE_TABLE"] }
  "dbx_dev.silver" = { engineers = ["USE_SCHEMA", "SELECT", "MODIFY", "CREATE_TABLE"] }
  "dbx_dev.gold" = {
    engineers = ["USE_SCHEMA", "SELECT"] # read-only on curated output
    bi_users  = ["USE_SCHEMA", "SELECT"] # read-only; no bronze/silver access at all
  }
}

# ---- SQL warehouse (classic, cost-conscious; BI/SQL users) -------------------
sql_warehouse_can_use    = ["engineers", "bi_users"]
warehouse_cluster_size   = "2X-Small"
warehouse_auto_stop_mins = 10

# ---- Lakebase (managed Postgres / OLTP; ADR-0013) ---------------------------
# OPT-IN per environment: lakebase_enabled = false creates nothing. dev turns it
# on; staging/prod set their own value when (if) they need OLTP.
# Right-sized + cheap for dev: smallest capacity, minimum retention, running.
# Flip lakebase_stopped = true to pause (storage-only billing) when idle.
# Access is GROUPS only; admins are implicit. engineers manage, others use.
lakebase_enabled        = true
lakebase_capacity       = "CU_1"
lakebase_retention_days = 2
lakebase_stopped        = false
lakebase_can_manage     = ["engineers"]
lakebase_can_use        = ["users", "bi_users"]
# Preserves the previous hardcoded behavior (clean teardown, no lingering storage).
lakebase_purge_on_delete = true

# ---- Tags (required set on every resource) ----------------------------------
tags = {
  Environment = "dev"
  Owner       = "data-platform-team"
  CostCenter  = "cc-dev-1001"
  ManagedBy   = "terraform"
  Project     = "azure-databricks-platform"
}
