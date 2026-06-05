###############################################################################
# hub-bootstrap (Terraform) — Minimal hub for testing prod-hub-connected
#
# Parity with infra/bicep/blueprints/hub-bootstrap/hub-bootstrap.bicep.
# Creates an RG containing hub VNet + Azure Firewall (Basic) + 7 PDNS zones.
#
# Outputs match the spoke param schema (hub_vnet_resource_id,
# hub_firewall_private_ip, existing_private_dns_zones).
#
# NOTE: Bicep + Terraform versions are EQUIVALENT but only ONE should be
# deployed at a time per subscription (they'd collide on RG name).
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.45" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type        = string
  description = "Target subscription GUID."
}

variable "workload" {
  type        = string
  default     = "klzfin"
  description = "Workload identifier used in resource names."
}

variable "environment" {
  type        = string
  default     = "prod"
  description = "Environment tag (affects RG name only)."
}

variable "location" {
  type        = string
  default     = "eastus2"
}

variable "hub_address_space" {
  type        = string
  default     = "10.0.0.0/16"
  description = "Hub VNet CIDR. Must NOT overlap the spoke (default spoke is 10.50.0.0/20)."
}

variable "firewall_subnet_cidr" {
  type        = string
  default     = "10.0.0.0/26"
  description = "AzureFirewallSubnet CIDR. Must be /26 or larger."
}

variable "firewall_management_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/26"
  description = "AzureFirewallManagementSubnet CIDR. REQUIRED for Firewall Basic SKU. Must be /26 or larger."
}

variable "tags" {
  type    = map(string)
  default = {
    workload = "klzfin"
    env      = "prod"
    purpose  = "hub-bootstrap"
    ownedBy  = "klz-accelerator"
  }
}

locals {
  rg_name     = "rg-${var.workload}-hub-${var.environment}"
  name_suffix = "${var.workload}-${var.environment}"
  pdns_zone_names = [
    "privatelink.vaultcore.azure.net",
    "privatelink.openai.azure.com",
    "privatelink.cognitiveservices.azure.com",
    "privatelink.search.windows.net",
    "privatelink.blob.core.windows.net",
    "privatelink.azure-api.net",
    "privatelink.documents.azure.com",
  ]
  pdns_short_keys = {
    "privatelink.vaultcore.azure.net"          = "vaultcore"
    "privatelink.openai.azure.com"             = "openai"
    "privatelink.cognitiveservices.azure.com"  = "cognitiveServices"
    "privatelink.search.windows.net"           = "search"
    "privatelink.blob.core.windows.net"        = "blob"
    "privatelink.azure-api.net"                = "apim"
    "privatelink.documents.azure.com"          = "cosmosSql"
  }
}

resource "azurerm_resource_group" "hub" {
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  address_space       = [var.hub_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.firewall_subnet_cidr]
}

resource "azurerm_subnet" "firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.firewall_management_subnet_cidr]
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-fw-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_public_ip" "firewall_management" {
  name                = "pip-fw-mgmt-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  name                = "fwpol-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = "Basic"
  threat_intelligence_mode = "Alert"
  tags                = var.tags
}

resource "azurerm_firewall" "this" {
  name                = "fw-${local.name_suffix}"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Basic"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipcfg"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  management_ip_configuration {
    name                 = "fw-mgmt-ipcfg"
    subnet_id            = azurerm_subnet.firewall_management.id
    public_ip_address_id = azurerm_public_ip.firewall_management.id
  }
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = toset(local.pdns_zone_names)
  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_link" {
  for_each              = azurerm_private_dns_zone.this
  name                  = "link-to-hub"
  resource_group_name   = azurerm_resource_group.hub.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
  tags                  = var.tags
}

output "resource_group_name" {
  value = azurerm_resource_group.hub.name
}

output "hub_vnet_resource_id" {
  value = azurerm_virtual_network.hub.id
}

output "hub_firewall_private_ip" {
  value = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "existing_private_dns_zones" {
  value = {
    for zone_name, zone in azurerm_private_dns_zone.this :
    local.pdns_short_keys[zone_name] => zone.id
  }
}
