using './../main.bicep'

// =====================================================================
// enterprise-hub-connected.sample.bicepparam — SAMPLE / NOT DEPLOYABLE AS-IS
//
// Demonstrates hub-connected mode for an enterprise environment with an
// EXISTING hub VNet + Azure Firewall + central private DNS zones (typical
// CAF/ALZ landing zone). Customer must fill in the three <REPLACE> blocks
// before this becomes deployable:
//   1. hubVnetResourceId       — full ARM resource ID of the hub VNet
//   2. hubFirewallPrivateIp    — internal IP of the hub's Azure Firewall
//   3. existingPrivateDnsZones — map of zoneFriendlyName → resource ID
//
// Two-step bring-up (recommended):
//   Day 0: set enableForcedTunneling = false → hub-connected but Internet
//          egress goes direct (saves a day of firewall-rule debugging).
//   Day 1: confirm peering + DNS resolution work, then flip
//          enableForcedTunneling = true and add the required firewall
//          policy rules for Azure Monitor, ACR, ARM, Entra ID, KV, Storage,
//          Foundry/OpenAI.
// =====================================================================

param workload = 'klzfin'
param env      = 'dev'
param location = 'eastus2'
param searchLocation = 'westus2'

// ----- Hub-connected networking -----
param networkMode = 'hub-connected'
param vnetAddressSpace = '10.50.0.0/20'

// REPLACE: full resource ID of the hub VNet you're peering to.
// Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>
param hubVnetResourceId = '/subscriptions/REPLACE-WITH-HUB-SUBSCRIPTION-GUID/resourceGroups/REPLACE-WITH-HUB-RG/providers/Microsoft.Network/virtualNetworks/REPLACE-WITH-HUB-VNET-NAME'

// REPLACE: hub firewall private IP (next-hop for 0/0 UDR).
// Find with: az network firewall ip-config list -g <hubRg> --firewall-name <fw> --query "[0].privateIpAddress" -o tsv
param hubFirewallPrivateIp = '10.0.0.4'

// Day-0 bring-up: set false to deploy without forced tunneling, validate DNS+peering, then flip true.
param enableForcedTunneling = false

// Reverse peer: requires hub-side write perms. Disabled by default — most ALZ
// deployments separate hub from spoke in different subs and the hub team
// creates the reverse peer out-of-band via a separate pipeline.
param createReverseHubPeer = false

// REPLACE: map of zoneFriendlyName → existing zone resource ID. Friendly keys
// match the catalog in modules/networking/private-dns.bicep. Omit any zones
// you don't need (e.g., if you're not using Cosmos for now). Spoke is linked
// to each zone you provide so PE → DNS resolution works from workload subnets.
param existingPrivateDnsZones = {
  vaultcore:         '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
  openai:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com'
  cognitiveServices: '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'
  search:            '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net'
  blob:              '/subscriptions/REPLACE/resourceGroups/REPLACE/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
  // Add more as needed: apim, cosmosSql, queue, table, file, dfs, web, acr,
  // appConfig, aiServices, cosmosMongo, cosmosCassandra, cosmosGremlin,
  // cosmosTable, cosmosAnalytics, cosmosPostgres
}

// ----- APIM publisher contact -----
param apimPublisherLocalPart = 'platform'
param apimPublisherDomain    = 'contoso.com'
param apimPublisherName      = 'Contoso AI Platform'

// ----- Components (enterprise baseline) -----
param components = {
  bastion:          { deploy: true,  sku: 'Standard' }
  jumpvm:           { deploy: true,  sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: true,  wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: true }   // pre-req for Foundry agent service injection (Stage B)
  apim:             { deploy: true,  sku: 'StandardV2', networkMode: 'internal' }
  standaloneSearch: { deploy: true,  sku: 'standard' }
  notifications:    { deploy: true }
  otelCollector:    { deploy: false }
}

param tags = {
  workload:   'klzfin'
  env:        'dev'
  owner:      'platform-team'
  costCenter: 'AI-Platform'
  managedBy:  'klz-accelerator-finops'
  purpose:    'enterprise-hub-connected'
  blueprint:  'hub-connected-with-bastion-appgw'
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

// Multi-project example — Stage B will add per-project agent-service injection,
// BYOR (Cosmos/Search/KV/Storage), and project connections.
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
