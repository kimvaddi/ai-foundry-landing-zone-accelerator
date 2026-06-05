# tflint-ignore-file: terraform_unused_declarations
###############################################################################
# hub-greenfield — STUB
#
# Future home for Azure/terraform-azurerm-avm-ptn-aiml-landing-zone wrapper.
# Today the AVM ptn module's v0.4.2 schema requires a non-trivial
# vnet_definition input that's mode-specific; deferred to a follow-up commit
# once we lock the variable surface (see plan p7-blueprints).
#
# Until then, hub-greenfield is documented as an unimplemented network_mode
# value. Customers wanting a brand-new hub can run the upstream AVM landing
# zone module directly and then point this stack at it via the
# "hub-connected" network_mode + hub_vnet_resource_id / hub_firewall_private_ip
# variables.
###############################################################################

variable "base_name" {
  type        = string
  description = "Workload + env composite name."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for hub resources."
}

variable "spoke_vnet_id" {
  type        = string
  default     = null
  description = "ID of the spoke VNet (passed for future peering wiring)."
}

variable "tags" {
  type        = map(string)
  default     = null
  description = "Tags applied to hub resources."
}

# TODO(p7): wire Azure/terraform-azurerm-avm-ptn-aiml-landing-zone here.

output "hub_vnet_id" {
  value       = null
  description = "Greenfield hub VNet ID (stub — not yet implemented)."
}

output "hub_firewall_private_ip" {
  value       = null
  description = "Greenfield hub firewall private IP (stub — not yet implemented)."
}
