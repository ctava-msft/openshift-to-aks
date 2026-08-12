resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  compact_prefix      = replace(var.name_prefix, "-", "")
  compact_environment = replace(var.environment, "-", "")
  resource_token      = "${local.compact_prefix}${local.compact_environment}${random_string.suffix.result}"
  common_tags = merge(var.tags, {
    application = "clinical-unit"
    environment = var.environment
    managed-by  = "terraform"
    workload    = "openshift-to-aks-pilot"
  })
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.name_prefix}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_container_registry" "main" {
  name                = substr("acr${local.resource_token}", 0, 50)
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = false
  tags                = local.common_tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.name_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.common_tags
}

resource "azurerm_cosmosdb_account" "main" {
  name                 = substr("cosmos-${local.resource_token}", 0, 44)
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  offer_type           = "Standard"
  kind                 = "MongoDB"
  mongo_server_version = "4.2"

  minimal_tls_version                   = "Tls12"
  public_network_access_enabled         = true
  network_acl_bypass_for_azure_services = false
  ip_range_filter                       = ["0.0.0.0"]

  capabilities {
    name = "EnableMongo"
  }

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
    zone_redundant    = false
  }

  tags = local.common_tags
}

resource "azurerm_cosmosdb_mongo_database" "main" {
  name                = var.cosmos_database_name
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_mongo_collection" "patients" {
  name                = var.cosmos_collection_name
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_mongo_database.main.name
  shard_key           = "_id"

  index {
    keys   = ["_id"]
    unique = true
  }

  index {
    keys   = ["mrn"]
    unique = false
  }
}

resource "azurerm_cognitive_account" "openai" {
  name                  = substr("oai-${local.resource_token}", 0, 64)
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = substr("oai-${local.resource_token}", 0, 64)

  local_auth_enabled            = true
  public_network_access_enabled = true
  tags                          = local.common_tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.openai_deployment_name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.openai_model_name
    version = var.openai_model_version
  }

  sku {
    name     = var.openai_sku_name
    capacity = var.openai_capacity
  }
}