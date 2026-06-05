using './../main.bicep'

// =====================================================================
// full.bicepparam — Stage A standalone landing zone with APIM
//
// Networking: standalone (we create our own private DNS zones + spoke VNet)
// Components: APIM ON (StandardV2, PE-mode — no VNet injection yet), Search ON
//
// Cost estimate (eastus2, 24h): ~$45-50
//   APIM StandardV2: ~$38/day  ← biggest line item, tear down within 24h
//   AI Search Basic: ~$2.50/day
//   Everything else combined: ~$5/day
//
// Use case: validate full AI gateway pipeline (APIM → Foundry MI → token-limit
// + emit-metrics policy → App Insights customMetrics → workbook).
// =====================================================================

param workload = 'klzfin'
param env      = 'dev'
param location = 'eastus2'
param searchLocation = 'westus2'

// ----- Stage A networking -----
param networkMode = 'standalone'
param vnetAddressSpace = '10.50.0.0/20'

// ----- APIM publisher contact -----
// Split into local-part + domain so source never contains a literal email-shaped
// string (some editor tooling obfuscates email literals → APIM rejects them).
param apimPublisherLocalPart = 'platform'
param apimPublisherDomain    = 'klzfin.com'
param apimPublisherName      = 'KLZ FinOps Platform'

// ----- Component toggles -----
param components = {
  bastion:          { deploy: false, sku: 'Standard' }
  jumpvm:           { deploy: false, sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: false, wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: false }
  apim:             { deploy: true,  sku: 'StandardV2', networkMode: 'none' }
  standaloneSearch: { deploy: true,  sku: 'basic' }
  notifications:    { deploy: false }
  otelCollector:    { deploy: false }
}

param tags = {
  workload:   'klzfin'
  env:        'dev'
  owner:      'platform-team'
  costCenter: 'AI-Platform'
  managedBy:  'klz-accelerator-finops'
  purpose:    'stage-a-full-standalone'
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
    displayName: 'Default project'
    description: 'Auto-created by klz-accelerator-finops full deploy.'
  }
]
