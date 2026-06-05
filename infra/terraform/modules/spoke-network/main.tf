###############################################################################
# spoke-network — Spoke VNet + 9-subnet catalog + per-subnet NSG + delegations
#
# Mirrors infra/bicep/modules/networking/spoke-vnet.bicep. Each subnet is
# gated by a toggle in var.components; AzureFirewallSubnet is gated by
# var.needs_firewall_subnet. NSGs are attached to every subnet EXCEPT
# AzureFirewallSubnet (rejected by ARM) and AzureBastionSubnet (Bastion-managed).
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_address_space" {
  type    = string
  default = "10.50.0.0/20"
}
variable "needs_firewall_subnet" {
  type    = bool
  default = false
}
variable "components" {
  type    = any
  default = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "enforce_apim_chokepoint" {
  type        = bool
  default     = false
  description = "When true, lock the PrivateEndpointSubnet so only APIMSubnet (+ explicit exceptions) can reach private endpoints. Flips PE subnet privateEndpointNetworkPolicies to NetworkSecurityGroupEnabled."
}

variable "allow_cae_bypass" {
  type        = bool
  default     = false
  description = "When chokepoint is on, also allow CAE subnet -> PE inbound."
}

variable "allow_agent_subnet_bypass" {
  type        = bool
  default     = true
  description = "When chokepoint is on, also allow AIFoundrySubnet -> PE inbound (Foundry Standard Agent Service needs this)."
}

locals {
  c = var.components

  apim_wants_subnet = (
    coalesce(try(local.c.apim.deploy, false), false)
    && coalesce(try(local.c.apim.network_mode, "none"), "none") != "none"
  )

  apim_delegation = (
    coalesce(try(local.c.apim.deploy, false), false) && startswith(coalesce(try(local.c.apim.sku, ""), ""), "StandardV2")
    ? "Microsoft.Web/serverFarms"
    : null
  )

  # Subnet catalog (alphabetical key order, mirrors Bicep)
  subnet_catalog = {
    AIFoundrySubnet = {
      enabled                           = true
      cidr                              = cidrsubnet(var.vnet_address_space, 4, 1)
      delegation                        = "Microsoft.App/environments"
      attach_nsg                        = true
      private_endpoint_network_policies = "Disabled"
    }
    APIMSubnet = {
      enabled                           = local.apim_wants_subnet
      cidr                              = cidrsubnet(var.vnet_address_space, 6, 20)
      delegation                        = local.apim_delegation
      attach_nsg                        = true
      private_endpoint_network_policies = "Enabled"
    }
    AppGatewaySubnet = {
      enabled                           = coalesce(try(local.c.app_gateway.deploy, false), false)
      cidr                              = cidrsubnet(var.vnet_address_space, 4, 4)
      delegation                        = null
      attach_nsg                        = true
      private_endpoint_network_policies = "Enabled"
    }
    AzureBastionSubnet = {
      enabled                           = coalesce(try(local.c.bastion.deploy, false), false)
      cidr                              = cidrsubnet(var.vnet_address_space, 6, 23)
      delegation                        = null
      attach_nsg                        = false
      private_endpoint_network_policies = "Enabled"
    }
    AzureFirewallSubnet = {
      enabled                           = var.needs_firewall_subnet
      cidr                              = cidrsubnet(var.vnet_address_space, 6, 24)
      delegation                        = null
      attach_nsg                        = false
      private_endpoint_network_policies = "Enabled"
    }
    ContainerAppEnvironmentSubnet = {
      enabled                           = coalesce(try(local.c.container_apps_env.deploy, false), false)
      cidr                              = cidrsubnet(var.vnet_address_space, 3, 1)
      delegation                        = "Microsoft.App/environments"
      attach_nsg                        = true
      private_endpoint_network_policies = "Enabled"
    }
    DevOpsBuildSubnet = {
      enabled                           = coalesce(try(local.c.buildvm.deploy, false), false)
      cidr                              = cidrsubnet(var.vnet_address_space, 6, 21)
      delegation                        = null
      attach_nsg                        = true
      private_endpoint_network_policies = "Enabled"
    }
    JumpboxSubnet = {
      enabled                           = coalesce(try(local.c.jumpvm.deploy, false), false)
      cidr                              = cidrsubnet(var.vnet_address_space, 6, 22)
      delegation                        = null
      attach_nsg                        = true
      private_endpoint_network_policies = "Enabled"
    }
    PrivateEndpointSubnet = {
      enabled                           = true
      cidr                              = cidrsubnet(var.vnet_address_space, 4, 0)
      delegation                        = null
      attach_nsg                        = true
      private_endpoint_network_policies = var.enforce_apim_chokepoint ? "NetworkSecurityGroupEnabled" : "Disabled"
    }
  }

  enabled_subnets = { for k, v in local.subnet_catalog : k => v if v.enabled }
  nsg_subnets     = { for k, v in local.enabled_subnets : k => v if v.attach_nsg }

  apim_subnet_cidr  = cidrsubnet(var.vnet_address_space, 6, 20)
  pe_subnet_cidr    = cidrsubnet(var.vnet_address_space, 4, 0)
  agent_subnet_cidr = cidrsubnet(var.vnet_address_space, 4, 1)
  cae_subnet_cidr   = cidrsubnet(var.vnet_address_space, 3, 1)
}

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_network_security_group" "subnet_nsg" {
  for_each            = local.nsg_subnets
  name                = "nsg-${lower(each.key)}-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# AppGW WAF v2 management plane rules (required by ARM)
resource "azurerm_network_security_rule" "appgw_gateway_manager" {
  count                       = contains(keys(local.nsg_subnets), "AppGatewaySubnet") ? 1 : 0
  name                        = "Allow-GatewayManager-65200-65535-Inbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["AppGatewaySubnet"].name
}

resource "azurerm_network_security_rule" "appgw_lb" {
  count                       = contains(keys(local.nsg_subnets), "AppGatewaySubnet") ? 1 : 0
  name                        = "Allow-AzureLoadBalancer-Inbound"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["AppGatewaySubnet"].name
}

###############################################################################
# Chokepoint NSG rules on PrivateEndpointSubnet (only when enforce_apim_chokepoint=true)
# Rules mirror infra/bicep/modules/networking/spoke-vnet.bicep PE rules.
###############################################################################

resource "azurerm_network_security_rule" "pe_allow_apim" {
  count                       = var.enforce_apim_chokepoint ? 1 : 0
  name                        = "Allow-APIM-To-PrivateEndpoints-443"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.apim_subnet_cidr
  destination_address_prefix  = local.pe_subnet_cidr
  description                 = "APIMSubnet -> PE subnet (chokepoint guarantee)"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["PrivateEndpointSubnet"].name
}

resource "azurerm_network_security_rule" "pe_allow_lb" {
  count                       = var.enforce_apim_chokepoint ? 1 : 0
  name                        = "Allow-AzureLoadBalancer-Inbound"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  description                 = "PE health probes from Azure Load Balancer"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["PrivateEndpointSubnet"].name
}

resource "azurerm_network_security_rule" "pe_allow_agent" {
  count                       = var.enforce_apim_chokepoint && var.allow_agent_subnet_bypass ? 1 : 0
  name                        = "Allow-AIFoundryAgentSubnet-To-PrivateEndpoints-443"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.agent_subnet_cidr
  destination_address_prefix  = local.pe_subnet_cidr
  description                 = "EXCEPTION: Foundry Agent Service must reach Foundry/Search PE directly. Set allow_agent_subnet_bypass=false to remove."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["PrivateEndpointSubnet"].name
}

resource "azurerm_network_security_rule" "pe_allow_cae" {
  count                       = var.enforce_apim_chokepoint && var.allow_cae_bypass ? 1 : 0
  name                        = "Allow-ContainerAppsEnv-To-PrivateEndpoints-443"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = local.cae_subnet_cidr
  destination_address_prefix  = local.pe_subnet_cidr
  description                 = "EXCEPTION: CAE-hosted runtimes call Foundry directly. Off by default."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["PrivateEndpointSubnet"].name
}

resource "azurerm_network_security_rule" "pe_deny_all" {
  count                       = var.enforce_apim_chokepoint ? 1 : 0
  name                        = "Deny-AllOther-Inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  description                 = "Explicit deny — chokepoint guarantee."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.subnet_nsg["PrivateEndpointSubnet"].name
}

resource "azurerm_subnet" "this" {
  for_each                          = local.enabled_subnets
  name                              = each.key
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.spoke.name
  address_prefixes                  = [each.value.cidr]
  private_endpoint_network_policies = each.value.private_endpoint_network_policies

  dynamic "delegation" {
    for_each = each.value.delegation == null ? [] : [each.value.delegation]
    content {
      name = "delegation"
      service_delegation {
        name    = delegation.value
        actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each                  = local.nsg_subnets
  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.subnet_nsg[each.key].id

  depends_on = [
    azurerm_network_security_rule.appgw_gateway_manager,
    azurerm_network_security_rule.appgw_lb,
    azurerm_network_security_rule.pe_allow_apim,
    azurerm_network_security_rule.pe_allow_lb,
    azurerm_network_security_rule.pe_allow_agent,
    azurerm_network_security_rule.pe_allow_cae,
    azurerm_network_security_rule.pe_deny_all,
  ]
}

# Optional public IP for APIM (StandardV2 external mode needs PIP on the runtime API gateway)
resource "azurerm_public_ip" "apim" {
  count               = local.apim_wants_subnet ? 1 : 0
  name                = "pip-apim-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  domain_name_label   = "apim-${var.base_name}"
  tags                = var.tags
}

output "vnet_id" { value = azurerm_virtual_network.spoke.id }
output "vnet_name" { value = azurerm_virtual_network.spoke.name }
output "subnet_ids" { value = { for k, s in azurerm_subnet.this : k => s.id } }
output "subnet_cidrs" { value = { for k, v in local.enabled_subnets : k => v.cidr } }
output "apim_pip_id" { value = length(azurerm_public_ip.apim) > 0 ? azurerm_public_ip.apim[0].id : null }
