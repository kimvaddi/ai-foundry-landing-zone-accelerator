using './../../main.bicep'

// =====================================================================
// blueprint: smoke (Bicep)
//
// Cheapest deploy: Foundation + Foundry + Search Basic. No networking.
// Use case: quickest CI smoke test. Cost ≈ $3-5/day. Deploy in <8 min.
// =====================================================================

param workload = 'klzfin'
param env      = 'smoke'
param location = 'eastus2'
param searchLocation = 'westus2'

param networkMode = 'standalone'

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
  env:       'smoke'
  blueprint: 'smoke'
  purpose:   'ci-smoke'
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
    displayName: 'Smoke project'
    description: 'Smoke-test Foundry project.'
  }
]
