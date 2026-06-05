// APIM Standard v2 — AI Gateway in front of Foundry / OpenAI.
//
// Topology decision (sandbox-friendly): APIM is left publicly accessible and
// calls Foundry via Foundry's public endpoint authenticated with MI. The VNet
// + PEs we provision in full mode give VNet-internal callers private access
// to Foundry/KV; production deployments should flip Foundry publicNetworkAccess
// to Disabled and add APIM VNet injection (requires a Public IP, see AVM
// param `publicIpAddressResourceId`).
//
// AI API, product, and policy attachment live in apim-ai-api.bicep.

@description('APIM service name (globally unique, 1-50 chars).')
@maxLength(50)
param name string

@description('Region.')
param location string

@description('Publisher email (required by ARM).')
param publisherEmail string

@description('Publisher display name.')
param publisherName string = 'KLZ FinOps Platform'

@description('SKU. BasicV2 = lowest cost (~$0.07/hr, no VNet injection). StandardV2 = cheapest V2 supporting VNet injection. Premium = classic premium with zone redundancy + multi-region (use for prod). Premium is the only tier that supports VNet injection with availability zones.')
@allowed([ 'BasicV2', 'StandardV2', 'Premium' ])
param sku string = 'StandardV2'

@description('SKU capacity (units).')
param skuCapacity int = 1

@description('Network mode. none = public (current behavior). external = VNet-injected with public gateway. internal = VNet-injected, internal IP only. Both external + internal require subnetResourceId; external additionally requires publicIpResourceId.')
@allowed([ 'none', 'external', 'internal' ])
param networkMode string = 'none'

@description('Subnet resource ID for VNet injection. REQUIRED when networkMode != none. StandardV2 = outbound VNet integration only (subnet delegated to Microsoft.Web/serverFarms). Premium = classic VNet injection (no delegation).')
param subnetResourceId string = ''

@description('Public IP resource ID for the gateway. Only used by classic Developer/Premium SKUs in VNet mode (AVM apim 0.9.1 supports `publicIpAddressResourceId` only for those tiers). V2 SKUs ignore this.')
param publicIpResourceId string = ''

@description('App Insights resource id (informational; emitted as output for downstream wiring).')
param appInsightsResourceId string

@description('App Insights connection string. Stored as a SECRET APIM named value and consumed by the applicationInsights logger. Required so the azure-openai-emit-token-metric policy (apim-policies/inbound-emit-metrics.xml) actually emits — without this, the policy is a no-op.')
@secure()
param appInsightsConnectionString string

@description('Log Analytics workspace for diagnostics.')
param workspaceResourceId string

@description('Tags.')
param tags object = {}

module apim 'br/public:avm/res/api-management/service:0.9.1' = {
  name: take('apim-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    sku: sku
    skuCapacity: skuCapacity
    publisherEmail: publisherEmail
    publisherName: publisherName
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkType: networkMode == 'none' ? 'None' : (networkMode == 'internal' ? 'Internal' : 'External')
    subnetResourceId: networkMode == 'none' ? null : subnetResourceId
    publicIpAddressResourceId: (networkMode == 'external') ? publicIpResourceId : null
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        logCategoriesAndGroups: [ { categoryGroup: 'allLogs' } ]
        metricCategories: [ { category: 'AllMetrics' } ]
      }
    ]
  }
}

// ---------------- Application Insights logger wiring -----------------
//
// Required for the `azure-openai-emit-token-metric` policy
// (apim-policies/inbound-emit-metrics.xml) to actually emit. AVM
// `api-management/service:0.9.1` only configures the LAW transport
// (Microsoft.Insights/diagnosticSettings); it does NOT register an
// App Insights logger on the APIM service. Without this block the
// policy is a silent no-op and customMetrics in App Insights stay
// empty regardless of CustomMetricsOptedInType=WithDimensions.
//
// `existing` reference is required because `parent:` needs a resource
// declaration, not a module reference.
resource apimSvc 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: name
  dependsOn: [
    apim
  ]
}

// Secret named value holding the App Insights connection string. The
// applicationInsights logger references it via the {{...}} placeholder
// syntax so the secret is never echoed back from the management API.
resource appiConnNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apimSvc
  name: 'appi-connection-string'
  properties: {
    displayName: 'appi-connection-string'
    secret: true
    value: appInsightsConnectionString
  }
}

resource appiLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apimSvc
  name: 'applicationinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for APIM (powers azure-openai-emit-token-metric + request telemetry).'
    resourceId: appInsightsResourceId
    credentials: {
      connectionString: '{{appi-connection-string}}'
    }
    isBuffered: true
  }
  dependsOn: [
    appiConnNamedValue
  ]
}

output resourceId string = apim.outputs.resourceId
output name string = apim.outputs.name
output gatewayUrl string = 'https://${name}.azure-api.net'
output principalId string = apim.outputs.?systemAssignedMIPrincipalId ?? ''
output appInsightsResourceIdOut string = appInsightsResourceId
output appInsightsLoggerId string = appiLogger.id
