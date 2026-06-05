###############################################################################
# compute/cae — Container Apps Environment (VNet-injected when subnet supplied)
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "workspace_resource_id" { type = string }
variable "infrastructure_subnet_id" {
  type    = string
  default = null
}
variable "internal_load_balancer_enabled" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "azurerm_log_analytics_workspace" "law" {
  name                = element(split("/", var.workspace_resource_id), length(split("/", var.workspace_resource_id)) - 1)
  resource_group_name = element(split("/", var.workspace_resource_id), 4)
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.base_name}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.law.id

  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = var.infrastructure_subnet_id == null ? false : var.internal_load_balancer_enabled
  zone_redundancy_enabled        = false

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.tags
}

output "id" { value = azurerm_container_app_environment.this.id }
output "name" { value = azurerm_container_app_environment.this.name }
output "default_domain" { value = azurerm_container_app_environment.this.default_domain }
