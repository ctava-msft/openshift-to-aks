variable "subscription_id" {
  description = "Azure subscription ID used for the pilot resources."
  type        = string
  nullable    = false
}

variable "location" {
  description = "Azure region for the shared application services."
  type        = string
  default     = "eastus2"
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

  validation {
    condition     = can(regex("^[a-z0-9-]{2,10}$", var.environment))
    error_message = "environment must be 2-10 lowercase letters, numbers, or hyphens."
  }
}

variable "cosmos_database_name" {
  description = "MongoDB database consumed by the clinical unit backend."
  type        = string
  default     = "clinical-rounds"
}

variable "cosmos_collection_name" {
  description = "MongoDB collection consumed by the clinical unit backend."
  type        = string
  default     = "patients"
}

variable "openai_model_name" {
  description = "Azure OpenAI model to deploy. Confirm availability and quota in the selected region."
  type        = string
  default     = "gpt-4o-mini"
}

variable "openai_model_version" {
  description = "Optional Azure OpenAI model version. Null selects the current regional default."
  type        = string
  default     = null
}

variable "openai_deployment_name" {
  description = "Deployment name passed to the backend container."
  type        = string
  default     = "gpt-4o-mini"
}

variable "openai_sku_name" {
  description = "Azure OpenAI deployment SKU."
  type        = string
  default     = "GlobalStandard"
}

variable "openai_capacity" {
  description = "Azure OpenAI deployment capacity in thousands of tokens per minute."
  type        = number
  default     = 10

  validation {
    condition     = var.openai_capacity >= 1
    error_message = "openai_capacity must be at least 1."
  }
}

variable "tags" {
  description = "Additional tags applied to Azure resources."
  type        = map(string)
  default     = {}
}