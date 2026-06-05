// Azure AI Search — Basic SKU for smoke (~$0.10/hour), MI auth.
@description('Search service name. 2-60 chars, lowercase + numbers + dashes.')
@maxLength(60)
param name string
param location string
param workspaceResourceId string
param tags object = {}

@description('SKU. Basic = cheapest paid tier suitable for vector search.')
@allowed([ 'free', 'basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2' ])
param sku string = 'basic'

@description('Number of replicas.')
param replicaCount int = 1

@description('Number of partitions.')
param partitionCount int = 1

@description('Public network access. Disable when the chokepoint is enforced and a private endpoint is in place.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('When true, disables key-based auth and forces AAD-only. Pair with publicNetworkAccess=Disabled for full lockdown.')
param disableLocalAuth bool = false

module search 'br/public:avm/res/search/search-service:0.12.2' = {
  name: take('srch-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    sku: sku
    replicaCount: replicaCount
    partitionCount: partitionCount
    publicNetworkAccess: publicNetworkAccess
    authOptions: disableLocalAuth ? null : {
      aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' }
    }
    disableLocalAuth: disableLocalAuth
    managedIdentities: { systemAssigned: true }
    semanticSearch: 'free'
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

output resourceId string = search.outputs.resourceId
output name string = search.outputs.name
