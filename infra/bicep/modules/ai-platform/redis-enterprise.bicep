// Azure Managed Redis (AMR) — backing store for APIM semantic cache.
//
// Why Azure Managed Redis?
//   APIM `azure-openai-semantic-cache-lookup` uses Redis as a VECTOR store
//   keyed by prompt embedding. Vector search requires the RediSearch module.
//   AMR (Balanced/ComputeOptimized/FlashOptimized/MemoryOptimized SKUs) is
//   the successor to the retired Azure Cache for Redis Enterprise tier and
//   supports RediSearch on all Balanced+ SKUs.
//
// SKU choice: Balanced_B0 is the cheapest tier (~$0.058/hr, ~$1.4/day).
// For dev/POC this is fine. Production should consider Balanced_B5 or
// higher and ComputeOptimized/MemoryOptimized variants depending on
// vector index cardinality.
//
// AuthN: APIM cache resource uses connection-string-with-key today. The
// private endpoint (when enforceApimChokepoint=true) means the key never
// leaves the VNet, mitigating exposure risk. AAD-only is on the roadmap.

@description('Cluster name. 1-60 chars, lowercase + numbers + dashes.')
@maxLength(60)
param name string
param location string
param tags object = {}

@description('SKU. Balanced_B0 = smallest AMR tier (~$1.4/day). Enterprise_* SKUs are RETIRED — no new creates allowed.')
@allowed([
  'Balanced_B0'
  'Balanced_B1'
  'Balanced_B3'
  'Balanced_B5'
  'Balanced_B10'
  'Balanced_B20'
  'Balanced_B50'
  'Balanced_B100'
  'ComputeOptimized_X3'
  'ComputeOptimized_X5'
  'ComputeOptimized_X10'
  'MemoryOptimized_M10'
  'MemoryOptimized_M20'
  'MemoryOptimized_M50'
])
param sku string = 'Balanced_B0'

@description('Database eviction policy. NoEviction is REQUIRED when RediSearch module is enabled (validated by Azure RP and TF provider).')
@allowed([ 'NoEviction' ])
param evictionPolicy string = 'NoEviction'

@description('Cluster policy. EnterpriseCluster is REQUIRED when RediSearch module is enabled on AMR.')
@allowed([ 'EnterpriseCluster' ])
param clusteringPolicy string = 'EnterpriseCluster'

@description('TLS minimum version. Pin to 1.2 (only allowed value).')
@allowed([ '1.2' ])
param minimumTlsVersion string = '1.2'

@description('Enable high availability replication. Required for AMR SKUs.')
@allowed([ 'Enabled', 'Disabled' ])
param highAvailability string = 'Enabled'

@description('Whether the cluster accepts traffic from the public internet. When enforceApimChokepoint=true at the root, set to Disabled and reach Redis via PE only.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

// ---------------- Key Vault wiring for secret handoff -----------------
// Bicep BCP426 prohibits passing `@secure()` outputs from a conditional
// module across module boundaries via `!` or ternary. Workaround: write
// the connection string to a Key Vault secret inside THIS module (the
// `db.listKeys()` call is internal — no cross-module crossing), then
// consume from main.bicep via `kv.getSecret(...)`.

@description('Key Vault name where the redis connection-string secret will be written. Must exist in the same resource group as this module.')
param keyVaultName string

@description('Secret name to write under the Key Vault. Default `redis-connection-string`.')
param secretName string = 'redis-connection-string'

resource cluster 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    minimumTlsVersion: minimumTlsVersion
    highAvailability: highAvailability
    publicNetworkAccess: publicNetworkAccess
  }
}

resource db 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: cluster
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: clusteringPolicy
    evictionPolicy: evictionPolicy
    accessKeysAuthentication: 'Enabled'
    modules: [
      {
        name: 'RediSearch'
      }
    ]
    persistence: {
      aofEnabled: false
      rdbEnabled: false
    }
  }
}

@description('Hostname (FQDN) of the Redis cluster — used to construct the APIM cache connection string.')
output hostName string = cluster.properties.hostName

@description('Cluster resource ID.')
output clusterId string = cluster.id

@description('Database resource ID.')
output databaseId string = db.id

@description('Key Vault secret name holding the APIM-formatted connection string. Consume via `kv.getSecret(secretName)` from the caller.')
output secretName string = secretName

// ---------------- Key Vault secret with the assembled conn string -----
resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

resource redisConnSecret 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' = {
  parent: kv
  name: secretName
  properties: {
    value: '${cluster.properties.hostName}:10000,password=${db.listKeys().primaryKey},ssl=True,abortConnect=False'
    contentType: 'redis-connection-string'
  }
}
