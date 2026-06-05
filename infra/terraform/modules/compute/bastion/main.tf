###############################################################################
# compute/bastion — Azure Bastion (Standard) with required PIP + AzureBastionSubnet lookup
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_id" { type = string }
variable "workspace_id" {
  type    = string
  default = null
}
variable "sku" {
  type    = string
  default = "Standard"
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  vnet_segments = split("/", var.vnet_id)
  vnet_name     = element(local.vnet_segments, length(local.vnet_segments) - 1)
}

data "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  virtual_network_name = local.vnet_name
  resource_group_name  = var.resource_group_name
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bas-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = data.azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_monitor_diagnostic_setting" "bastion" {
  name                       = "diag-bas"
  target_resource_id         = azurerm_bastion_host.this.id
  log_analytics_workspace_id = var.workspace_id

  enabled_log { category = "BastionAuditLogs" }
  enabled_metric { category = "AllMetrics" }
}

output "id" { value = azurerm_bastion_host.this.id }
output "name" { value = azurerm_bastion_host.this.name }
output "dns_name" { value = azurerm_bastion_host.this.dns_name }
