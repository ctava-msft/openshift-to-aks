data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_container_registry" "main" {
  name                = var.container_registry_name
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azuread_service_principal" "aro_resource_provider" {
  client_id = "f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875"
}

locals {
  compact_prefix              = replace(var.name_prefix, "-", "")
  cluster_name                = substr("aro-${var.name_prefix}-${var.environment}", 0, 30)
  cluster_resource_group_name = coalesce(var.cluster_resource_group_name, "rg-${var.name_prefix}-aro-${var.environment}")
  common_tags = merge(var.tags, {
    application = "clinical-unit"
    environment = var.environment
    managed-by  = "terraform"
    platform    = "aro"
    workload    = "openshift-to-aks-pilot"
  })
}

resource "azurerm_resource_group" "cluster" {
  name     = local.cluster_resource_group_name
  location = data.azurerm_resource_group.main.location
  tags     = local.common_tags
}

resource "azuread_application" "cluster" {
  display_name = "sp-${var.name_prefix}-aro-${var.environment}"
}

resource "azuread_service_principal" "cluster" {
  client_id = azuread_application.cluster.client_id
}

resource "azuread_service_principal_password" "cluster" {
  service_principal_id = azuread_service_principal.cluster.object_id
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.name_prefix}-aro-${var.environment}"
  resource_group_name = azurerm_resource_group.cluster.name
  location            = azurerm_resource_group.cluster.location
  address_space       = var.vnet_address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "control_plane" {
  name                                          = "snet-aro-control-plane"
  resource_group_name                           = azurerm_resource_group.cluster.name
  virtual_network_name                          = azurerm_virtual_network.main.name
  address_prefixes                              = var.control_plane_subnet_address_prefixes
  service_endpoints                             = ["Microsoft.ContainerRegistry", "Microsoft.Storage"]
  private_link_service_network_policies_enabled = false
}

resource "azurerm_subnet" "workers" {
  name                                          = "snet-aro-workers"
  resource_group_name                           = azurerm_resource_group.cluster.name
  virtual_network_name                          = azurerm_virtual_network.main.name
  address_prefixes                              = var.worker_subnet_address_prefixes
  service_endpoints                             = ["Microsoft.ContainerRegistry", "Microsoft.Storage"]
  private_link_service_network_policies_enabled = false
}

resource "azurerm_role_assignment" "cluster_network" {
  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azuread_service_principal.cluster.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cluster_contributor" {
  scope                            = azurerm_resource_group.cluster.id
  role_definition_name             = "Contributor"
  principal_id                     = azuread_service_principal.cluster.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "resource_provider_network" {
  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = data.azuread_service_principal.aro_resource_provider.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = data.azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azuread_service_principal.cluster.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_redhat_openshift_cluster" "main" {
  name                = local.cluster_name
  resource_group_name = azurerm_resource_group.cluster.name
  location            = azurerm_resource_group.cluster.location
  tags                = local.common_tags

  cluster_profile {
    domain                      = var.cluster_domain
    version                     = var.openshift_version
    pull_secret                 = var.redhat_pull_secret
    fips_enabled                = var.fips_enabled
    managed_resource_group_name = "mrg-${local.compact_prefix}-aro-${var.environment}"
  }

  network_profile {
    pod_cidr      = var.pod_cidr
    service_cidr  = var.service_cidr
    outbound_type = "Loadbalancer"
  }

  main_profile {
    vm_size   = var.control_plane_vm_size
    subnet_id = azurerm_subnet.control_plane.id
  }

  worker_profile {
    vm_size      = var.worker_vm_size
    disk_size_gb = var.worker_disk_size_gb
    node_count   = var.worker_node_count
    subnet_id    = azurerm_subnet.workers.id
  }

  api_server_profile {
    visibility = var.api_server_visibility
  }

  ingress_profile {
    visibility = var.ingress_visibility
  }

  service_principal {
    client_id     = azuread_application.cluster.client_id
    client_secret = azuread_service_principal_password.cluster.value
  }

  timeouts {
    create = "120m"
    update = "120m"
    delete = "120m"
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.cluster_contributor,
    azurerm_role_assignment.cluster_network,
    azurerm_role_assignment.resource_provider_network,
  ]
}