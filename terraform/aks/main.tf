data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_container_registry" "main" {
  name                = var.container_registry_name
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azurerm_log_analytics_workspace" "main" {
  name                = var.log_analytics_workspace_name
  resource_group_name = data.azurerm_resource_group.main.name
}

locals {
  common_tags = merge(var.tags, {
    application = "clinical-unit"
    environment = var.environment
    managed-by  = "terraform"
    platform    = "aks"
    workload    = "openshift-to-aks-pilot"
  })
  cluster_admin_object_ids = setunion(
    var.cluster_admin_object_ids,
    toset([data.azurerm_client_config.current.object_id])
  )
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.name_prefix}-aks-${var.environment}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.node_subnet_address_prefixes
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name_prefix}-aks-${var.environment}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "control_plane_network" {
  scope                = azurerm_subnet.nodes.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.name_prefix}-${var.environment}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  dns_prefix          = "${replace(var.name_prefix, "-", "")}-${var.environment}"
  kubernetes_version  = var.kubernetes_version

  sku_tier                          = "Standard"
  cost_analysis_enabled             = true
  local_account_disabled            = true
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  azure_policy_enabled              = true
  automatic_upgrade_channel         = "stable"
  node_os_upgrade_channel           = "NodeImage"
  image_cleaner_enabled             = true
  image_cleaner_interval_hours      = 168

  default_node_pool {
    name                         = "system"
    vm_size                      = var.node_vm_size
    auto_scaling_enabled         = true
    min_count                    = var.node_min_count
    max_count                    = var.node_max_count
    node_count                   = var.node_min_count
    only_critical_addons_enabled = false
    os_disk_size_gb              = 128
    type                         = "VirtualMachineScaleSets"
    vnet_subnet_id               = azurerm_subnet.nodes.id
    zones                        = var.availability_zones

    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  web_app_routing {
    dns_zone_ids             = []
    default_nginx_controller = "External"
  }

  tags = local.common_tags

  depends_on = [azurerm_role_assignment.control_plane_network]
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = local.cluster_admin_object_ids

  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}