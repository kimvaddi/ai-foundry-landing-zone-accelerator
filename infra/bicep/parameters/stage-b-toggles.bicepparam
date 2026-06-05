using './../main.bicep'

// =====================================================================
// stage-b-toggles.bicepparam — Exercises every Stage B P2/P4/P5 toggle
//
// This is the validation fixture for Stage B. Enables:
//   • APIM with StandardV2 + VNet outbound integration (P4)
//   • CAE in VNet-injected internal mode (P5)
//   • Bastion + Jumpbox + BuildAgent (P5)
//   • AppGW WAF_v2 (P5)
//   • Foundry agent injection + account capability host (P2)
//   • BYOR connection to standalone Search auto-wired (P2 + P3)
//
// Cost estimate (eastus2, 24h):
//   APIM StandardV2 + VNet: ~$38/day
//   AppGW WAF_v2:           ~$10/day
//   Bastion Standard:       ~$5/day
//   Two VMs (B2s each):     ~$2/day each, $0 if deallocated
//   AI Search Basic:        ~$2.50/day
//   CAE (Consumption, idle): ~$0
//   ≈ $60-65/day  ← tear down within 24h after validation.
//
// PRE-DEPLOY:
//   1. Set $env:KLZ_JUMPVM_PWD to a strong Windows password BEFORE running
//      `az deployment sub create --parameters jumpvmAdminPassword=$env:KLZ_JUMPVM_PWD ...`
//   2. Set $env:KLZ_BUILDVM_SSH_KEY to your ssh-ed25519 public key text.
//      ssh-keygen -t ed25519 -f ~/.ssh/klz_buildvm -N "" ; Get-Content ~/.ssh/klz_buildvm.pub
// =====================================================================

param workload = 'klzfin'
param env      = 'dev'
param location = 'eastus2'
// AI Search Basic capacity in eastus2 is constrained; westus2 is reliable.
param searchLocation = 'westus2'

// ----- Networking (standalone for cheap validation) -----
param networkMode = 'standalone'
param vnetAddressSpace = '10.50.0.0/20'

// ----- APIM publisher contact -----
param apimPublisherLocalPart = 'platform'
param apimPublisherDomain    = 'klzfin.com'
param apimPublisherName      = 'KLZ FinOps Platform'

// ----- Component toggles -----
// Flip all five P5 toggles on so every compute module exercises.
// NOTE: containerAppsEnv.deploy = false during validation because eastus2 is
// currently throwing ManagedEnvironmentCapacityHeavyUsageError (AKS regional
// capacity). The CAE module path is exercised by the build (compiles clean)
// and by the unit smoke profile; we'll re-validate live once eastus2 capacity
// recovers, or by using a different region.
param components = {
  bastion:          { deploy: true,  sku: 'Standard' }
  jumpvm:           { deploy: true,  sku: 'Standard_B2s' }
  buildvm:          { deploy: true,  sku: 'Standard_B2s' }
  appGateway:       { deploy: true,  wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: false }
  // APIM StandardV2 with VNet outbound integration (delegation to
  // Microsoft.Web/serverFarms on APIMSubnet, picked up by spoke-vnet).
  apim:             { deploy: true,  sku: 'StandardV2', networkMode: 'external' }
  standaloneSearch: { deploy: true,  sku: 'basic' }
  notifications:    { deploy: false }
  otelCollector:    { deploy: false }
}

// CAE in internal mode is fine for standalone validation — workloads can reach
// it from the JumpVM via Bastion.
param containerAppsEnvInternal = true

// ----- VM credentials (provide at CLI: --parameters jumpvmAdminPassword=$env:KLZ_JUMPVM_PWD) -----
// Leaving these empty here so the param file is safe to commit; deploy command
// MUST override both when the corresponding toggles are on.
// param jumpvmAdminPassword = ''
// param buildvmSshPublicKey = ''

param tags = {
  workload:   'klzfin'
  env:        'dev'
  owner:      'platform-team'
  costCenter: 'AI-Platform'
  managedBy:  'klz-accelerator-finops'
  purpose:    'stage-b-toggle-validation'
}

param modelDeployments = [
  {
    name: 'gpt-4o-mini'
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
    sku:   { name: 'GlobalStandard', capacity: 10 }
  }
]

// ----- Foundry: two projects + agent injection + BYOR Search auto-wire -----
param foundryProjects = [
  {
    name:        'default'
    displayName: 'Default project'
    description: 'Default project for Stage B agent + BYOR validation.'
  }
  {
    name:        'agents'
    displayName: 'Agents project'
    description: 'Project that hosts agents via the Standard Agent Service.'
  }
]

// Agent Service network injection on the AIFoundrySubnet (always created).
param enableFoundryAgentInjection = true

// Capability host (kind=Agents) at account level — required for agents to land
// on the injected network.
//
// NOTE: Disabled for live validation in eastus2. capabilityHost provisioning
// uses the same AKS-fronted infrastructure as Container App Environments and
// hits ManagedEnvironmentCapacityHeavyUsageError / silent 50-min timeouts when
// the region is capacity-constrained (observed against eastus2). Re-enable when
// validating in a region with available AKS capacity, or after the upstream
// service stabilizes.
param createFoundryCapabilityHost = false

// BYOR: wire the standalone Search service into the `default` project.
// `target` left empty → main.bicep's autoWireSearchConnection fills it with the
// computed search endpoint.
param foundryByorConnections = [
  {
    projectName: 'default'
    name:        'standalone-search'
    category:    'CognitiveSearch'
    target:      ''           // auto-filled to https://srch-<suffix>.search.windows.net
    authType:    'AAD'        // requires Search Index Data Contributor role on Search for project MI
    isSharedToAll: true
  }
]

param autoWireSearchConnection = true
