output "cluster_name" {
  description = "AKS cluster name."
  value       = azurerm_kubernetes_cluster.main.name
}

output "resource_group_name" {
  description = "Resource group containing AKS."
  value       = data.azurerm_resource_group.main.name
}

output "kubernetes_version" {
  description = "Kubernetes version running on AKS."
  value       = azurerm_kubernetes_cluster.main.current_kubernetes_version
}

output "oidc_issuer_url" {
  description = "AKS OIDC issuer for workload identity federation."
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "get_credentials_command" {
  description = "Azure CLI command that merges AKS credentials into the current kubeconfig."
  value       = "az aks get-credentials --resource-group ${data.azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
}