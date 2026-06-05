using './../../main.bicep'

// =====================================================================
// blueprint: prod-standalone-with-fw (Bicep) — DEFERRED
//
// Standalone-with-firewall mode (module owns the spoke FW + policy + UDR).
// Full prod surface: Bastion + Jump + Build + AppGW + APIM internal + CAE.
//
// NOTE: standalone-with-firewall is DEFERRED in the engine. Becomes
// deployable once the firewall + UDR-attach two-pass deploy lands.
// =====================================================================

param workload = 'klzfin'
param env      = 'prod'
param location = 'eastus2'
param searchLocation = 'westus2'

// NOTE: 'standalone-with-firewall' engine support is DEFERRED (Stage A blocked on two-pass deploy).
// Until the engine adds it, this blueprint deploys 'standalone' and leaves the firewall as a
// follow-up manual provisioning step. The `components.appGateway/bastion` toggles still light up
// the surrounding surface.
param networkMode = 'standalone'
param vnetAddressSpace = '10.50.0.0/20'

param apimPublisherLocalPart = 'platform'
param apimPublisherDomain    = 'klzfin.com'
param apimPublisherName      = 'KLZ FinOps Platform'

param components = {
  bastion:          { deploy: true,  sku: 'Standard' }
  jumpvm:           { deploy: true,  sku: 'Standard_B2s' }
  buildvm:          { deploy: true,  sku: 'Standard_B2s' }
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
  blueprint: 'prod-standalone-with-fw'
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
]

param enableFoundryAgentInjection = true
param createFoundryCapabilityHost = true

// AI Gateway safety + semantic cache (all 3 ON for prod baseline)
param enableContentSafety         = true
param enablePromptShields         = true
param safetyThreshold             = 4
param enableSemanticCache         = true
param embeddingsDeploymentName    = 'text-embedding-3-large'
param apimProductTokensPerMinute  = 100000
