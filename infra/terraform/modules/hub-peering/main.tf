###############################################################################
# hub-peering — Spoke <-> hub VNet peering
#
# Mirrors infra/bicep/modules/networking/hub-peering.bicep +
# hub-peering-reverse.bicep. Always creates the spoke->hub peer. Optionally
# creates the reverse hub->spoke peer when:
#   * create_reverse_hub_peer = true, AND
#   * the hub is in the SAME subscription as the spoke (parity with Bicep —
#     cross-sub reverse peer needs nested deployments and is deferred).
###############################################################################

variable "spoke_vnet_name" {
  type        = string
  description = "Spoke VNet name (in spoke_resource_group_name)."
}

variable "spoke_resource_group_name" {
  type        = string
  description = "Resource group containing the spoke VNet."
}

variable "spoke_vnet_id" {
  type        = string
  description = "Full resource ID of the spoke VNet (needed for the reverse peer)."
}

variable "hub_vnet_resource_id" {
  type        = string
  description = "Full resource ID of the hub VNet — /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>."
}

variable "peer_name_suffix" {
  type        = string
  default     = "hub"
  description = "Friendly suffix for the spoke->hub peer name (becomes peer-to-<suffix>)."
}

variable "allow_virtual_network_access" {
  type    = bool
  default = true
}

variable "allow_forwarded_traffic" {
  type        = bool
  default     = true
  description = "Required when forced tunneling through hub firewall (NVA scenarios)."
}

variable "allow_gateway_transit" {
  type        = bool
  default     = false
  description = "Hub-side: whether the hub gateway can be used by the spoke. Only set true if hub has a VPN/ExpressRoute gateway."
}

variable "use_remote_gateways" {
  type        = bool
  default     = false
  description = "Spoke-side: whether the spoke uses the hub gateway for on-prem connectivity."
}

variable "create_reverse_hub_peer" {
  type        = bool
  default     = false
  description = "Create the reverse hub->spoke peer. Only honored when the hub is in the same subscription."
}

# Parse hub resource ID -> subscription/RG/name (parity with Bicep split logic).
locals {
  hub_segments         = split("/", var.hub_vnet_resource_id)
  hub_subscription_id  = length(local.hub_segments) >= 3 ? local.hub_segments[2] : data.azurerm_client_config.current.subscription_id
  hub_resource_group   = length(local.hub_segments) >= 5 ? local.hub_segments[4] : ""
  hub_vnet_name        = length(local.hub_segments) >= 9 ? local.hub_segments[8] : ""
  same_sub             = local.hub_subscription_id == data.azurerm_client_config.current.subscription_id
  reverse_peer_enabled = var.create_reverse_hub_peer && local.same_sub
}

data "azurerm_client_config" "current" {}

# Spoke -> hub peer (always)
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-to-${var.peer_name_suffix}"
  resource_group_name          = var.spoke_resource_group_name
  virtual_network_name         = var.spoke_vnet_name
  remote_virtual_network_id    = var.hub_vnet_resource_id
  allow_virtual_network_access = var.allow_virtual_network_access
  allow_forwarded_traffic      = var.allow_forwarded_traffic
  allow_gateway_transit        = false
  use_remote_gateways          = var.use_remote_gateways
}

# Hub -> spoke peer (optional, same-sub only)
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count                        = local.reverse_peer_enabled ? 1 : 0
  name                         = "peer-from-${var.spoke_vnet_name}"
  resource_group_name          = local.hub_resource_group
  virtual_network_name         = local.hub_vnet_name
  remote_virtual_network_id    = var.spoke_vnet_id
  allow_virtual_network_access = var.allow_virtual_network_access
  allow_forwarded_traffic      = var.allow_forwarded_traffic
  allow_gateway_transit        = var.allow_gateway_transit
  use_remote_gateways          = false

  depends_on = [azurerm_virtual_network_peering.spoke_to_hub]
}

output "spoke_to_hub_peer_id" { value = azurerm_virtual_network_peering.spoke_to_hub.id }
output "reverse_peer_attempted" { value = local.reverse_peer_enabled }
output "hub_subscription_id" { value = local.hub_subscription_id }
output "hub_resource_group" { value = local.hub_resource_group }
output "hub_vnet_name" { value = local.hub_vnet_name }
