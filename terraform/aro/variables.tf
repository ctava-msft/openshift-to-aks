variable "subscription_id" {
  description = "Azure subscription ID containing the shared foundation."
  type        = string
  nullable    = false
}

variable "resource_group_name" {
  description = "Shared resource group created by the foundation stack and containing ACR."
  type        = string
  nullable    = false
}

variable "cluster_resource_group_name" {
  description = "Optional dedicated ARO resource group name. Null generates one from name_prefix and environment."
  type        = string
  default     = null
}

variable "container_registry_name" {
  description = "Container registry created by the foundation stack."
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

variable "openshift_version" {
  description = "ARO-supported OpenShift version returned by az aro get-versions for the selected region."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^4\\.[0-9]+(\\.[0-9]+)?$", var.openshift_version))
    error_message = "openshift_version must be a supported 4.x version, for example 4.19.21."
  }
}

variable "cluster_domain" {
  description = "Unique DNS label used by ARO for API and application endpoints."
  type        = string
  default     = "clinical-unit-pilot"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.cluster_domain))
    error_message = "cluster_domain must be 4-32 lowercase letters, numbers, or hyphens and cannot end with a hyphen."
  }
}

variable "redhat_pull_secret" {
  description = "Optional Red Hat pull-secret JSON. Obtain it from console.redhat.com."
  type        = string
  default     = null
  sensitive   = true
}

variable "fips_enabled" {
  description = "Enable FIPS validated cryptographic modules on the ARO cluster."
  type        = bool
  default     = false
}

variable "api_server_visibility" {
  description = "ARO API server visibility."
  type        = string
  default     = "Public"

  validation {
    condition     = contains(["Public", "Private"], var.api_server_visibility)
    error_message = "api_server_visibility must be Public or Private."
  }
}

variable "ingress_visibility" {
  description = "ARO application ingress visibility."
  type        = string
  default     = "Public"

  validation {
    condition     = contains(["Public", "Private"], var.ingress_visibility)
    error_message = "ingress_visibility must be Public or Private."
  }
}

variable "vnet_address_space" {
  description = "ARO virtual network address space."
  type        = list(string)
  default     = ["10.20.0.0/22"]
}

variable "control_plane_subnet_address_prefixes" {
  description = "ARO control-plane subnet address prefixes."
  type        = list(string)
  default     = ["10.20.0.0/23"]
}

variable "worker_subnet_address_prefixes" {
  description = "ARO worker subnet address prefixes."
  type        = list(string)
  default     = ["10.20.2.0/23"]
}

variable "pod_cidr" {
  description = "Non-overlapping OpenShift pod CIDR."
  type        = string
  default     = "10.128.0.0/14"
}

variable "service_cidr" {
  description = "Non-overlapping OpenShift service CIDR."
  type        = string
  default     = "172.30.0.0/16"
}

variable "control_plane_vm_size" {
  description = "VM SKU for the three managed ARO control-plane nodes."
  type        = string
  default     = "Standard_D8s_v5"
}

variable "worker_vm_size" {
  description = "VM SKU for ARO worker nodes."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "worker_node_count" {
  description = "ARO worker node count. ARO requires at least three workers."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_node_count >= 3
    error_message = "worker_node_count must be at least 3."
  }
}

variable "worker_disk_size_gb" {
  description = "ARO worker OS disk size in GiB."
  type        = number
  default     = 128

  validation {
    condition     = var.worker_disk_size_gb >= 128
    error_message = "worker_disk_size_gb must be at least 128 GiB."
  }
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default     = {}
}