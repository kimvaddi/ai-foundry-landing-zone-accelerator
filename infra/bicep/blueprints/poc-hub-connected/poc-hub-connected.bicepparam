using './../../main.bicep'

// =====================================================================
// blueprint: poc-hub-connected (Bicep) — SAMPLE / NOT DEPLOYABLE AS-IS
//
// Hub-connected (BYO hub VNet + firewall + central PDNS zones), Foundry
// agent service ON, CAE ON. APIM/AppGW/Bastion off (PoC, not prod).
// Customer MUST fill in the three <REPLACE> placeholders below.
// =====================================================================

param workload = 'klzfin'
param env      = 'poc'
param location = 'eastus2'
param searchLocation = 'westus2'

param networkMode = 'hub-connected'
param vnetAddressSpace = '10.50.0.0/20'

param hubVnetResourceId       = '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/virtualNetworks/REPLACE'
param hubFirewallPrivateIp    = '10.0.0.4'
param enableForcedTunneling   = false
param createReverseHubPeer    = false

param existingPrivateDnsZones = {
  vaultcore:         '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
  openai:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com'
  cognitiveServices: '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'
  search:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net'
  blob:              '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
}

param components = {
  bastion:          { deploy: false, sku: 'Standard' }
  jumpvm:           { deploy: false, sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: false, wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: true }
  apim:             { deploy: false, sku: 'StandardV2', networkMode: 'none' }
  standaloneSearch: { deploy: true,  sku: 'basic' }
  notifications:    { deploy: false }
  otelCollector:    { deploy: false }
}

param tags = {
  workload:  'klzfin'
  env:       'poc'
  blueprint: 'poc-hub-connected'
}

param modelDeployments = [
  {
    name: 'gpt-4o-mini'
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
    sku:   { name: 'GlobalStandard', capacity: 10 }
  }
]

param foundryProjects = [
  {
    name:        'default'
    displayName: 'PoC hub-connected project'
    description: 'PoC project with Foundry agent service.'
  }
]

param enableFoundryAgentInjection = true
param createFoundryCapabilityHost = false
