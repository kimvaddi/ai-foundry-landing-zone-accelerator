###############################################################################
# blueprint: prod-hub-connected (Terraform) — SAMPLE / NOT DEPLOYABLE AS-IS
#
# Full prod surface attached to a customer-managed hub (typical ALZ).
# Bastion + Jump + AppGW + APIM internal + CAE + Foundry agents + multi-project
# + BYOR Search. APIM in `internal` mode (VNet-injected).
#
# Customer MUST fill in:
#   - hub_vnet_resource_id
#   - hub_firewall_private_ip
#   - existing_private_dns_zones (map)
###############################################################################

subscription_id = "REPLACE-WITH-YOUR-SUBSCRIPTION-GUID"
workload        = "klzfin"
environment     = "prod"
location        = "eastus2"
# Co-locate Search with Foundry so we can attach a private endpoint when
# enforce_apim_chokepoint = true. Override to a fallback region only if you
# turn the chokepoint off OR set components.standalone_search.deploy = false.
search_location = "eastus2"

network_mode       = "hub-connected"
vnet_address_space = "10.50.0.0/20"

# Recommended enterprise default: APIM AI Gateway is the SINGLE chokepoint.
# Flips Foundry + Search public_network_access to Disabled, attaches a PE for
# Search, and enables NSG rules on the PrivateEndpointSubnet that only allow
# APIMSubnet (+ optional agent / CAE exceptions) to reach the PEs.
# Requires apim.deploy = true AND apim.network_mode in {external, internal}.
enforce_apim_chokepoint   = true
allow_cae_bypass          = false
allow_agent_subnet_bypass = true

hub_vnet_resource_id    = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/virtualNetworks/REPLACE"
hub_firewall_private_ip = "10.0.0.4"

# Day 0: false → bring up without forced tunneling, validate.
# Day 1: flip to true + add firewall FQDN rules for Azure Monitor, ACR, ARM,
#        Entra ID, KV, Storage, Foundry/OpenAI.
enable_forced_tunneling = false
create_reverse_hub_peer = false

existing_private_dns_zones = {
  vaultcore         = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  openai            = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
  cognitiveServices = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
  search            = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net"
  blob              = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  apim              = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.azure-api.net"
  cosmosSql         = "/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com"
}

apim_publisher = {
  local_part = "platform"
  domain     = "contoso.com"
  name       = "Contoso AI Platform"
}

components = {
  bastion            = { deploy = true, sku = "Standard" }
  jumpvm             = { deploy = true, sku = "Standard_B2s" }
  buildvm            = { deploy = false }
  app_gateway        = { deploy = true, sku = "WAF_v2", waf_enabled = true }
  container_apps_env = { deploy = true }
  apim               = { deploy = true, sku = "StandardV2", network_mode = "internal" }
  standalone_search  = { deploy = true, sku = "standard" }
  notifications      = { deploy = true }
  otel_collector     = { deploy = false }
}

tags = {
  workload  = "klzfin"
  env       = "prod"
  blueprint = "prod-hub-connected"
}

model_deployments = [
  {
    name  = "gpt-4o"
    model = { format = "OpenAI", name = "gpt-4o", version = "2024-11-20" }
    sku   = { name = "GlobalStandard", capacity = 50 }
  },
  {
    name  = "text-embedding-3-large"
    model = { format = "OpenAI", name = "text-embedding-3-large", version = "1" }
    sku   = { name = "Standard", capacity = 10 }
  }
]

foundry_projects = [
  {
    name         = "platform"
    display_name = "Platform team"
    description  = "Foundry workspace for the central AI platform team."
  },
  {
    name         = "business-unit-a"
    display_name = "Business unit A"
    description  = "Isolated workspace for BU-A apps and agents."
  }
]

enable_foundry_agent_injection = true
create_foundry_capability_host = true

foundry_byor_connections = [
  {
    project_name     = "platform"
    name             = "standalone-search"
    category         = "CognitiveSearch"
    target           = ""
    auth_type        = "AAD"
    is_shared_to_all = true
  }
]

auto_wire_search_connection = true

# AI Gateway safety + semantic cache (all 3 ON for prod baseline)
enable_content_safety          = true
enable_prompt_shields          = true
safety_threshold               = 4
enable_semantic_cache          = true
embeddings_deployment_name     = "text-embedding-3-large"
apim_product_tokens_per_minute = 100000
