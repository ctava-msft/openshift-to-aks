output "cluster_name" {
  description = "ARO cluster name."
  value       = azurerm_redhat_openshift_cluster.main.name
}

output "resource_group_name" {
  description = "Resource group containing ARO."
  value       = azurerm_resource_group.cluster.name
}

output "console_url" {
  description = "OpenShift web console URL."
  value       = azurerm_redhat_openshift_cluster.main.console_url
}

output "api_server_url" {
  description = "OpenShift API server URL."
  value       = azurerm_redhat_openshift_cluster.main.api_server_profile[0].url
}

output "list_credentials_command" {
  description = "Azure CLI command that returns the initial kubeadmin credentials."
  value       = "az aro list-credentials --resource-group ${azurerm_resource_group.cluster.name} --name ${azurerm_redhat_openshift_cluster.main.name}"
}

output "service_principal_client_id" {
  description = "Client ID of the dedicated ARO service principal."
  value       = azuread_application.cluster.client_id
}

output "service_principal_client_secret" {
  description = "Client secret used only to create the namespace-scoped ACR pull secret."
  value       = azuread_service_principal_password.cluster.value
  sensitive   = true
}