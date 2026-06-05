###############################################################################
# blueprint: poc-hub-connected (Terraform)  — SAMPLE / NOT DEPLOYABLE AS-IS
#
# Hub-connected (BYO hub VNet + firewall + central PDNS zones), Foundry agent
# service ON, CAE ON. APIM/AppGW/Bastion still off (this is a PoC, not prod).
#
# Customer MUST fill in:
#   - hub_vnet_resource_id
#   - hub_firewall_private_ip (only used when enable_forced_tunneling=true)
#   - existing_private_dns_zones (map)
###############################################################################

subscription_id = "REPLACE-WITH-YOUR-SUBSCRIPTION-GUID"
workload        = "klzfin"
environment     = "poc"
location        = "eastus2"
search_location = "westus2"

network_mode       = "hub-connected"
vnet_address_space = "10.50.0.0/20"

hub_vnet_resource_id    = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/virtualNetworks/REPLACE"
hub_firewall_private_ip = "10.0.0.4"
enable_forced_tunneling = false
create_reverse_hub_peer = false

existing_private_dns_zones = {
  vaultcore         = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  openai            = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
  cognitiveServices = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
  search            = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net"
  blob              = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
}

components = {
  bastion            = { deploy = false }
  jumpvm             = { deploy = false }
  buildvm            = { deploy = false }
  app_gateway        = { deploy = false }
  container_apps_env = { deploy = true }
  apim               = { deploy = false }
  standalone_search  = { deploy = true, sku = "basic" }
  notifications      = { deploy = false }
  otel_collector     = { deploy = false }
}

tags = {
  workload  = "klzfin"
  env       = "poc"
  blueprint = "poc-hub-connected"
}

model_deployments = [
  {
    name  = "gpt-4o-mini"
    model = { format = "OpenAI", name = "gpt-4o-mini", version = "2024-07-18" }
    sku   = { name = "GlobalStandard", capacity = 10 }
  }
]

foundry_projects = [
  {
    name         = "default"
    display_name = "PoC hub-connected project"
    description  = "PoC project with Foundry agent service."
  }
]

enable_foundry_agent_injection = true
create_foundry_capability_host = false
