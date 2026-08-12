output "resource_group_name" {
  description = "Shared resource group name used by the AKS and ARO stacks."
  value       = azurerm_resource_group.main.name
}

output "location" {
  description = "Azure region containing the shared services."
  value       = azurerm_resource_group.main.location
}

output "container_registry_id" {
  description = "Azure Container Registry resource ID."
  value       = azurerm_container_registry.main.id
}

output "container_registry_name" {
  description = "Azure Container Registry name."
  value       = azurerm_container_registry.main.name
}

output "container_registry_login_server" {
  description = "Azure Container Registry login server used in image references."
  value       = azurerm_container_registry.main.login_server
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azurerm_log_analytics_workspace.main.id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name used by the AKS stack."
  value       = azurerm_log_analytics_workspace.main.name
}

output "cosmosdb_database" {
  description = "Cosmos DB MongoDB database name."
  value       = azurerm_cosmosdb_mongo_database.main.name
}

output "cosmosdb_collection" {
  description = "Cosmos DB MongoDB collection name."
  value       = azurerm_cosmosdb_mongo_collection.patients.name
}

output "cosmosdb_username" {
  description = "Cosmos DB MongoDB username."
  value       = azurerm_cosmosdb_account.main.name
}

output "cosmosdb_password" {
  description = "Cosmos DB MongoDB account key."
  value       = azurerm_cosmosdb_account.main.primary_key
  sensitive   = true
}

output "cosmosdb_host" {
  description = "Cosmos DB MongoDB hostname."
  value       = "${azurerm_cosmosdb_account.main.name}.mongo.cosmos.azure.com"
}

output "cosmosdb_options" {
  description = "Connection options expected by the backend."
  value       = "ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&appName=@${azurerm_cosmosdb_account.main.name}@"
}

output "azure_openai_endpoint" {
  description = "Azure OpenAI endpoint."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "azure_openai_key" {
  description = "Azure OpenAI account key."
  value       = azurerm_cognitive_account.openai.primary_access_key
  sensitive   = true
}

output "azure_openai_deployment_name" {
  description = "Azure OpenAI deployment consumed by the backend."
  value       = azurerm_cognitive_deployment.chat.name
}

output "azure_openai_api_version" {
  description = "API version retained for compatibility with the backend configuration."
  value       = "2024-08-01-preview"
}