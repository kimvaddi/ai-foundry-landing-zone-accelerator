// Throwaway smoke-test wrapper for Tier 2.6 pricing-seed validation.
// Creates a temporary LAW + uses the production custom-tables.bicep module
// so we exercise the EXACT module the customer deploys. RG is torn down
// after the smoke test.

targetScope = 'resourceGroup'

@description('Location for the LAW + DCE + DCRs.')
param location string = resourceGroup().location

@description('Suffix used to disambiguate LAW name.')
param nameSuffix string

var lawName = 'law-tier26-${nameSuffix}'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

module tables '../../infra/bicep/modules/finops/custom-tables.bicep' = {
  name: 'finops-custom-tables'
  params: {
    workspaceName:       law.name
    workspaceResourceId: law.id
    location:            location
    tags: {
      purpose:  'tier2.6-smoke-test'
      teardown: 'true'
    }
  }
}

output lawName string = law.name
output lawResourceId string = law.id
output dceEndpoint string = tables.outputs.dceEndpoint
output pricingDcrImmutableId string = tables.outputs.pricingDcrImmutableId
output quotaDcrImmutableId   string = tables.outputs.quotaDcrImmutableId
output agentAuditDcrId       string = tables.outputs.agentAuditDcrId
