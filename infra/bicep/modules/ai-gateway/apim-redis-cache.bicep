// APIM external cache resource — points the APIM service at Redis Enterprise
// for semantic cache lookups. Separated from apim-ai-api.bicep because
// secure outputs can only cross a module boundary via direct reference
// (no ternary), which would block a conditional invocation from main.bicep.

@description('APIM service name (parent).')
param apimName string

@description('Redis Enterprise connection string (secure passthrough from redis-enterprise module).')
@secure()
param redisConnectionString string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource redisNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'redis-connection-string'
  properties: {
    displayName: 'redis-connection-string'
    value: redisConnectionString
    secret: true
  }
}

resource externalCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = {
  parent: apim
  name: 'default'
  properties: {
    description: 'Azure Managed Redis Enterprise — backing store for semantic cache'
    connectionString: redisConnectionString
    useFromLocation: 'default'
  }
  dependsOn: [
    redisNamedValue
  ]
}

output cacheName string = externalCache.name
