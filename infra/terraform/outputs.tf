###############################################################################
# outputs.tf — top-level exports (mirrors Bicep main outputs)
###############################################################################

output "platform_resource_group" {
  value       = azurerm_resource_group.platform.name
  description = "Name of the platform resource group."
}

output "foundry_resource_group" {
  value       = azurerm_resource_group.foundry.name
  description = "Name of the foundry resource group."
}

output "spoke_vnet_id" {
  value       = module.spoke_network.vnet_id
  description = "Resource ID of the spoke VNet."
}

output "spoke_subnet_ids" {
  value       = module.spoke_network.subnet_ids
  description = "Map of subnet name → resource ID for the spoke VNet."
}

output "foundry_account_id" {
  value       = module.foundry_stack.account_id
  description = "Resource ID of the Foundry account."
}

output "foundry_account_endpoint" {
  value       = module.foundry_stack.account_endpoint
  description = "Public endpoint of the Foundry account."
}

output "foundry_project_ids" {
  value       = module.foundry_stack.project_ids
  description = "Map of project name → resource ID."
}

output "search_service_endpoint" {
  value       = length(module.search) > 0 ? module.search[0].endpoint : null
  description = "Standalone AI Search service endpoint (when deployed)."
}

output "apim_gateway_url" {
  value       = length(module.apim) > 0 ? module.apim[0].gateway_url : null
  description = "APIM gateway URL (when deployed)."
}

output "bastion_dns_name" {
  value       = length(module.bastion) > 0 ? module.bastion[0].dns_name : null
  description = "Bastion host DNS name (when deployed)."
}

output "log_analytics_workspace_id" {
  value       = module.foundation.workspace_resource_id
  description = "Log Analytics workspace resource ID."
}

output "name_suffix" {
  value       = local.name_suffix
  description = "Deterministic name suffix used for all resource names."
}
