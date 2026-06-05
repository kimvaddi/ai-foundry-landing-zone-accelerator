using './../main.bicep'

// =====================================================================
// dev.bicepparam — Stage A cheap-standalone baseline (was: smoke mode)
//
// Networking: standalone (we create our own private DNS zones + spoke VNet)
// Components: APIM off (saves ~$38/day), AI Search ON (~$0.10/hr Basic)
//
// Cost estimate (eastus2, 24h): ~$3-5
//   LAW: free tier (<5GB)
//   App Insights: free tier
//   KV: free
//   Foundry S0: free at idle
//   AI Search Basic: ~$2.50/day
//   VNet + 21 PDNS zones: ~$0.30/day
//   2 PEs (Foundry + KV): ~$1.50/day
//
// Live-validation use: this is the file the user runs for the cheapest
// end-to-end smoke test of the Stage A networking refactor.
// =====================================================================

param workload = 'klzfin'
param env      = 'dev'
param location = 'eastus2'
// AI Search Basic capacity in eastus2 is constrained; westus2 is reliable.
// Cross-region PE is not supported, so Search keeps public + IP-firewall when separated.
param searchLocation = 'westus2'

// ----- Stage A networking -----
param networkMode = 'standalone'
param vnetAddressSpace = '10.50.0.0/20'

// ----- Component toggles (Stage A baseline) -----
param components = {
  bastion:          { deploy: false, sku: 'Standard' }
  jumpvm:           { deploy: false, sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: false, wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: false }
  // APIM off in dev — saves ~$38/day. Flip to true once you want to validate
  // the AI gateway + token-limit + emit-metrics policy chain end-to-end.
  apim:             { deploy: false, sku: 'StandardV2', networkMode: 'none' }
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
  purpose:    'stage-a-standalone-validation'
}

// Single small model deployment — keeps token spend negligible
param modelDeployments = [
  {
    name: 'gpt-4o-mini'
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
    sku:   { name: 'GlobalStandard', capacity: 10 }
  }
]

param foundryProjects = [
  {
    name:        'smoke'
    displayName: 'Smoke validation project'
    description: 'Auto-created by klz-accelerator-finops dev deploy.'
  }
]
