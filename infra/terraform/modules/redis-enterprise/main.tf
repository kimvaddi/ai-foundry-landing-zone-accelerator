###############################################################################
# redis-enterprise — Azure Managed Redis (AMR) with RediSearch module
#
# Backing store for APIM semantic cache. RediSearch is REQUIRED for vector
# similarity search.
#
# NOTE: Azure Cache for Redis Enterprise SKUs (Enterprise_E*) are RETIRED.
# Must use AMR SKUs (Balanced_*, ComputeOptimized_*, MemoryOptimized_*,
# FlashOptimized_*). azurerm 4.76+ exposes the unified `azurerm_managed_redis`
# resource (cluster + database in one block, since AMR cluster:database is 1:1).
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      configuration_aliases = []
    }
  }
}

variable "name" {
  type        = string
  description = "Cluster name."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group."
}

variable "sku_name" {
  type        = string
  default     = "Balanced_B0"
  description = "AMR SKU. Balanced_B0 is the cheapest (~$1.4/day). Override to Balanced_B5+ / MemoryOptimized_M* for prod. Enterprise_E* SKUs are RETIRED."
}

variable "public_network_access" {
  type        = string
  default     = "Enabled"
  description = "Whether the cluster accepts traffic from the public internet. Set to Disabled when reachable via PE only."
}

variable "high_availability_enabled" {
  type        = bool
  default     = true
  description = "Replication for fault tolerance. Required for production. Cannot be disabled after create."
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_managed_redis" "this" {
  name                      = var.name
  location                  = var.location
  resource_group_name       = var.resource_group_name
  sku_name                  = var.sku_name
  high_availability_enabled = var.high_availability_enabled
  public_network_access     = var.public_network_access
  tags                      = var.tags

  default_database {
    client_protocol                    = "Encrypted"
    clustering_policy                  = "EnterpriseCluster"
    eviction_policy                    = "NoEviction"
    access_keys_authentication_enabled = true

    module {
      name = "RediSearch"
    }
  }
}

output "host_name" {
  value       = azurerm_managed_redis.this.hostname
  description = "Cluster FQDN."
}

output "cluster_id" {
  value = azurerm_managed_redis.this.id
}

output "database_id" {
  value       = azurerm_managed_redis.this.default_database[0].id
  description = "Default database resource ID."
}

output "primary_key" {
  value     = azurerm_managed_redis.this.default_database[0].primary_access_key
  sensitive = true
}

output "connection_string" {
  value       = "${azurerm_managed_redis.this.hostname}:${azurerm_managed_redis.this.default_database[0].port},password=${azurerm_managed_redis.this.default_database[0].primary_access_key},ssl=True,abortConnect=False"
  sensitive   = true
  description = "Pre-built connection string for APIM external cache resource."
}
