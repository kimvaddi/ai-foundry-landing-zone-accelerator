###############################################################################
# route-table — Forced-tunnel UDR (0.0.0.0/0 -> hub firewall NVA) +
# per-subnet attachment.
#
# Mirrors infra/bicep/modules/networking/route-table.bicep + udr-attach.bicep.
# Deployed only when network_mode = hub-connected AND enable_forced_tunneling
# = true AND hub_firewall_private_ip is set (gated by caller).
#
# Attaches to every subnet in var.subnet_ids. Caller curates the list per
# Bicep main.bicep:udrCandidateSubnets — always AIFoundrySubnet; toggle-gated
# APIM/AppGW/CAE/Build/Jumpbox; never PrivateEndpointSubnet/AzureBastionSubnet/
# AzureFirewallSubnet.
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }

variable "hub_firewall_private_ip" {
  type        = string
  description = "Next-hop IP of the hub firewall (VirtualAppliance route destination)."
}

variable "subnet_ids" {
  type        = map(string)
  description = "Map of subnet-key (e.g. AIFoundrySubnet) -> full subnet resource ID. Route table is attached to every entry."
}

variable "disable_bgp_route_propagation" {
  type        = bool
  default     = true
  description = "Disable on-prem BGP route propagation into the spoke (PSRule Azure.RouteTable.BGP). Default true matches Bicep."
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_route_table" "this" {
  name                          = "rt-${var.base_name}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  bgp_route_propagation_enabled = !var.disable_bgp_route_propagation
  tags                          = var.tags

  route {
    name                   = "default-to-hub-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.hub_firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "this" {
  for_each       = var.subnet_ids
  subnet_id      = each.value
  route_table_id = azurerm_route_table.this.id
}

output "route_table_id" { value = azurerm_route_table.this.id }
output "attached_subnet_keys" { value = keys(var.subnet_ids) }
