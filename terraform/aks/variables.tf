variable "subscription_id" {
  description = "Azure subscription ID containing the shared foundation."
  type        = string
  nullable    = false
}

variable "resource_group_name" {
  description = "Resource group created by the foundation stack."
  type        = string
  nullable    = false
}

variable "container_registry_name" {
  description = "Container registry created by the foundation stack."
  type        = string
  nullable    = false
}

variable "log_analytics_workspace_name" {
  description = "Log Analytics workspace created by the foundation stack."
  type        = string
  nullable    = false
}

variable "name_prefix" {
  description = "Short lowercase prefix used in Azure resource names."
  type        = string
  default     = "clinical-unit"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "name_prefix must be 3-19 lowercase letters, numbers, or hyphens and start with a letter."
  }
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "pilot"
}

variable "kubernetes_version" {
  description = "Optional supported AKS Kubernetes version. Null selects Azure's current default."
  type        = string
  default     = null
}

variable "node_vm_size" {
  description = "VM SKU for the AKS system node pool."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "node_min_count" {
  description = "Minimum AKS node count."
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum AKS node count."
  type        = number
  default     = 5
}

variable "availability_zones" {
  description = "Availability zones for AKS nodes. Use an empty list where zones are unavailable."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "vnet_address_space" {
  description = "AKS virtual network address space."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "node_subnet_address_prefixes" {
  description = "AKS node subnet address prefixes."
  type        = list(string)
  default     = ["10.10.0.0/22"]
}

variable "pod_cidr" {
  description = "Non-overlapping Azure CNI Overlay pod CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Non-overlapping Kubernetes service CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "Kubernetes DNS address inside service_cidr."
  type        = string
  default     = "10.0.0.10"
}

variable "api_server_authorized_ip_ranges" {
  description = "Optional public CIDRs allowed to reach the AKS API server. Empty allows all networks."
  type        = list(string)
  default     = []
}

variable "cluster_admin_object_ids" {
  description = "Additional Entra object IDs granted Azure Kubernetes Service RBAC Cluster Admin."
  type        = set(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default     = {}
}

check "node_count_range" {
  assert {
    condition     = var.node_min_count >= 1 && var.node_max_count >= var.node_min_count
    error_message = "node_min_count must be at least 1 and node_max_count must be greater than or equal to it."
  }
}