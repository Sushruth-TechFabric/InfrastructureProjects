# =============================================================================
# modules/databricks-workspace — SECURE WORKSPACE (VNet injection + SCC)
# -----------------------------------------------------------------------------
# This creates the customer-side workspace resource. The three security pillars
# expressed here:
#
#   1. VNet INJECTION — the compute plane runs in OUR spoke VNet's delegated
#      host + container subnets (custom_parameters below), not a Databricks-
#      managed VNet. That's what puts clusters behind our firewall + PEs.
#
#   2. SECURE CLUSTER CONNECTIVITY (no_public_ip = true) — cluster nodes get NO
#      public IP and open NO inbound ports; they dial OUT to the SCC relay. The
#      control plane can never connect inward.
#
#   3. FRONT-END STAYS PUBLIC (public_network_access_enabled = true) — by design.
#      Users/CI reach the workspace UI+API over the internet, gated by Entra ID +
#      (added later) IP access lists. We do NOT deploy front-end Private Link.
#      The BACK-END Private Link (clusters -> control plane) is a private endpoint
#      created in the environment root on the PE subnet.
#
# sku MUST be "premium" — Unity Catalog, cluster policies, IP access lists, and
# private link are all premium-tier features.
# =============================================================================

resource "azurerm_databricks_workspace" "this" {
  name                = var.workspace_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "premium"

  # Databricks creates and owns this resource group (holds the managed VNet-less
  # plumbing, DBFS storage, etc.). We name it per convention for clarity.
  managed_resource_group_name = var.managed_resource_group_name

  # Front-end reachable over the internet (identity-gated). Back-end/compute/data
  # remain private. This is the platform's deliberate front-end decision.
  public_network_access_enabled = true

  # Databricks manages the required NSG rules itself via its network intent
  # policy; "NoAzureDatabricksRules" tells it we (the customer) are not supplying
  # extra rules it must account for.
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    # ---- VNet injection: point the workspace at our spoke + delegated subnets.
    virtual_network_id  = var.virtual_network_id
    public_subnet_name  = var.host_subnet_name
    private_subnet_name = var.container_subnet_name

    # Bind the subnets' NSG associations so Databricks validates injection only
    # after the NSGs are attached.
    public_subnet_network_security_group_association_id  = var.host_subnet_nsg_association_id
    private_subnet_network_security_group_association_id = var.container_subnet_nsg_association_id

    # ---- Secure Cluster Connectivity: no public IP on cluster nodes.
    no_public_ip = true
  }

  tags = var.tags
}
