// =====================================================================
// private-dns.bicep — Private DNS zones for the spoke
//
// Replaces the legacy 4-zone module with the full 21-zone catalog needed
// for the Foundry + APIM + AI Search + KV + Storage + Cosmos surface.
//
// Two operating modes (driven by `createZones`):
//   createZones = true   → standalone mode. Create all 21 zones in this RG,
//                          link each to the spoke VNet.
//   createZones = false  → hub-connected mode. Reference existing zones (IDs
//                          provided via `existingZones`); optionally link
//                          the spoke VNet to each (recommended unless the
//                          hub runs a DNS Private Resolver that the spoke
//                          uses via vnet.dhcpOptions.dnsServers).
//
// PE → zone mapping is per-subresource (vault→vaultcore, account→[openai,
// cognitiveservices], etc.). Callers receive zoneIds as a map and pick the
// right one(s) per PE — never blanket-attach all 21.
// =====================================================================

@description('Spoke VNet resource ID — used for VNet links.')
param vnetResourceId string

@description('Tags.')
param tags object = {}

@description('If true, create all 21 zones in this RG. If false, expect IDs in `existingZones`.')
param createZones bool = true

@description('When createZones=false, map of zoneFriendlyName→resourceId for zones living in the hub. Friendly names: vaultcore, apim, cosmosSql, cosmosMongo, cosmosCassandra, cosmosGremlin, cosmosTable, cosmosAnalytics, cosmosPostgres, blob, queue, table, file, dfs, web, search, acr, appConfig, openai, aiServices, cognitiveServices.')
param existingZones object = {}

@description('When createZones=false, also link the spoke VNet to each referenced zone. Default true. Set false only if you use a hub DNS Private Resolver.')
param linkExistingZonesToSpoke bool = true

// ----------------------- Zone catalog ---------------------------------
// Friendly key → DNS suffix mapping. Same key set is used in outputs for
// stable downstream wiring regardless of createZones.

var zoneCatalog = {
  vaultcore:          'privatelink.vaultcore.azure.net'
  apim:               'privatelink.azure-api.net'
  cosmosSql:          'privatelink.documents.azure.com'
  cosmosMongo:        'privatelink.mongo.cosmos.azure.com'
  cosmosCassandra:    'privatelink.cassandra.cosmos.azure.com'
  cosmosGremlin:      'privatelink.gremlin.cosmos.azure.com'
  cosmosTable:        'privatelink.table.cosmos.azure.com'
  cosmosAnalytics:    'privatelink.analytics.cosmos.azure.com'
  cosmosPostgres:     'privatelink.postgres.cosmos.azure.com'
  #disable-next-line no-hardcoded-env-urls
  blob:               'privatelink.blob.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  queue:              'privatelink.queue.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  table:              'privatelink.table.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  file:               'privatelink.file.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  dfs:                'privatelink.dfs.core.windows.net'
  #disable-next-line no-hardcoded-env-urls
  web:                'privatelink.web.core.windows.net'
  search:             'privatelink.search.windows.net'
  acr:                'privatelink.azurecr.io'
  appConfig:          'privatelink.azconfig.io'
  openai:             'privatelink.openai.azure.com'
  aiServices:         'privatelink.services.ai.azure.com'
  cognitiveServices:  'privatelink.cognitiveservices.azure.com'
}

var zoneEntries = items(zoneCatalog) // alphabetical by key

// ----------------------- Create path -----------------------------------

module zones 'br/public:avm/res/network/private-dns-zone:0.7.1' = [for entry in zoneEntries: if (createZones) {
  name: take('pdns-${entry.key}-${uniqueString(vnetResourceId, entry.value)}', 64)
  params: {
    name: entry.value
    tags: tags
    virtualNetworkLinks: empty(vnetResourceId) ? [] : [
      {
        name: 'link-spoke'
        virtualNetworkResourceId: vnetResourceId
        registrationEnabled: false
      }
    ]
  }
}]

// ----------------------- Reference path (hub-connected) ----------------
// Link the spoke to each EXISTING zone in its host RG. This is a child
// resource on the existing zone, deployed cross-RG via a per-zone nested
// module so we land at the zone's host RG scope.

var existingZoneEntries = [for entry in zoneEntries: {
  key: entry.key
  zoneName: entry.value
  zoneId: existingZones[?entry.key] ?? ''
}]

module linkExisting 'private-dns-link.bicep' = [for entry in existingZoneEntries: if (!createZones && linkExistingZonesToSpoke && !empty(entry.zoneId)) {
  name: take('link-${entry.key}-${uniqueString(vnetResourceId, entry.zoneName)}', 64)
  scope: resourceGroup(split(entry.zoneId, '/')[2], split(entry.zoneId, '/')[4])
  params: {
    zoneName: entry.zoneName
    linkName: 'link-${uniqueString(vnetResourceId)}'
    vnetResourceId: vnetResourceId
  }
}]

// ----------------------- Outputs (map by friendly key) -----------------
// In create mode → resource IDs from the new zones.
// In reference mode → resource IDs from existingZones (empty string if not provided).

output zoneIds object = reduce(
  zoneEntries,
  {},
  (acc, entry) => union(acc, {
    '${entry.key}': createZones
      ? resourceId('Microsoft.Network/privateDnsZones', entry.value)
      : (existingZones[?entry.key] ?? '')
  })
)

// Zone names (for diagnostics / debugging / TF parity).
output zoneNames object = zoneCatalog
