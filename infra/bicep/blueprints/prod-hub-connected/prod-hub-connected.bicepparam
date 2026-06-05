using './../../main.bicep'

// =====================================================================
// blueprint: prod-hub-connected (Bicep) — SAMPLE / NOT DEPLOYABLE AS-IS
//
// Full prod surface attached to a customer-managed hub (typical ALZ).
// Bastion + Jump + AppGW + APIM internal + CAE + Foundry agents +
// multi-project + BYOR Search.
//
// Customer MUST fill in:
//   - hubVnetResourceId
//   - hubFirewallPrivateIp
//   - existingPrivateDnsZones (map)
// =====================================================================

param workload = 'klzfin'
param env      = 'prod'
param location = 'eastus2'
// Co-locate Search with Foundry so we can attach a private endpoint when
// enforceApimChokepoint = true. Override to a fallback region only if you turn
// the chokepoint off OR set components.standaloneSearch.deploy = false.
param searchLocation = 'eastus2'

param networkMode = 'hub-connected'
param vnetAddressSpace = '10.50.0.0/20'

// Recommended enterprise default: APIM AI Gateway is the SINGLE chokepoint.
// Flips Foundry + Search publicNetworkAccess to Disabled, attaches a PE for
// Search, and enables NSG rules on the PrivateEndpointSubnet that only allow
// APIMSubnet (+ optional agent / CAE exceptions) to reach the PEs.
// Requires apim.deploy = true AND apim.networkMode in {external, internal}.
param enforceApimChokepoint   = true
param allowCaeBypass          = false
param allowAgentSubnetBypass  = true

param hubVnetResourceId    = '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/virtualNetworks/REPLACE'
param hubFirewallPrivateIp = '10.0.0.4'

// Day-0 bring-up: false. Day-1: flip true and add the required firewall FQDN rules.
param enableForcedTunneling = false
param createReverseHubPeer  = false

param existingPrivateDnsZones = {
  vaultcore:         '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
  openai:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com'
  cognitiveServices: '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'
  search:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net'
  blob:              '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
  apim:              '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.azure-api.net'
  cosmosSql:         '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com'
}

param apimPublisherLocalPart = 'platform'
param apimPublisherDomain    = 'contoso.com'
param apimPublisherName      = 'Contoso AI Platform'

param components = {
  bastion:          { deploy: true,  sku: 'Standard' }
  jumpvm:           { deploy: true,  sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: true,  wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: true }
  apim:             { deploy: true,  sku: 'StandardV2', networkMode: 'internal' }
  standaloneSearch: { deploy: true,  sku: 'standard' }
  notifications:    { deploy: true }
  otelCollector:    { deploy: false }
}

param tags = {
  workload:  'klzfin'
  env:       'prod'
  blueprint: 'prod-hub-connected'
}

param modelDeployments = [
  {
    name: 'gpt-4o'
    model: { format: 'OpenAI', name: 'gpt-4o', version: '2024-11-20' }
    sku:   { name: 'GlobalStandard', capacity: 50 }
  }
  {
    name: 'text-embedding-3-large'
    model: { format: 'OpenAI', name: 'text-embedding-3-large', version: '1' }
    sku:   { name: 'Standard', capacity: 10 }
  }
]

param foundryProjects = [
  {
    name:        'platform'
    displayName: 'Platform team'
    description: 'Foundry workspace for the central AI platform team.'
  }
  {
    name:        'business-unit-a'
    displayName: 'Business unit A'
    description: 'Isolated workspace for BU-A apps and agents.'
  }
]

param enableFoundryAgentInjection = true
param createFoundryCapabilityHost = true

param foundryByorConnections = [
  {
    projectName:   'platform'
    name:          'standalone-search'
    category:      'CognitiveSearch'
    target:        ''
    authType:      'AAD'
    isSharedToAll: true
  }
]

param autoWireSearchConnection = true

// AI Gateway safety + semantic cache (all 3 ON for prod baseline)
param enableContentSafety         = true
param enablePromptShields         = true
param safetyThreshold             = 4
param enableSemanticCache         = true
param embeddingsDeploymentName    = 'text-embedding-3-large'
param apimProductTokensPerMinute  = 100000
