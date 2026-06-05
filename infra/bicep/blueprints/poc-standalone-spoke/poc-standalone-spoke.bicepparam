using './../../main.bicep'

// =====================================================================
// blueprint: poc-standalone-spoke (Bicep)
//
// Standalone networking + Foundry + Search + 21 PDNS zones + PEs.
// Compute toggles off. APIM off.
// Cost ≈ $5-8/day.
// =====================================================================

param workload = 'klzfin'
param env      = 'poc'
param location = 'eastus2'
param searchLocation = 'westus2'

param networkMode = 'standalone'
param vnetAddressSpace = '10.50.0.0/20'

param components = {
  bastion:          { deploy: false, sku: 'Standard' }
  jumpvm:           { deploy: false, sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: false, wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: false }
  apim:             { deploy: false, sku: 'StandardV2', networkMode: 'none' }
  standaloneSearch: { deploy: true,  sku: 'basic' }
  notifications:    { deploy: false }
  otelCollector:    { deploy: false }
}

param tags = {
  workload:  'klzfin'
  env:       'poc'
  blueprint: 'poc-standalone-spoke'
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
    displayName: 'PoC project'
    description: 'PoC standalone-spoke Foundry project.'
  }
]
