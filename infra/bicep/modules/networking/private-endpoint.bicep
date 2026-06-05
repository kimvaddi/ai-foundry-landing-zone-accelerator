// Generic Private Endpoint wrapper around AVM.
//
// Caller provides: target resource id, group id ("account", "vault", etc),
// PE subnet id, list of private DNS zone ids to register A records into.

@description('Friendly PE name.')
param name string

@description('Region.')
param location string

@description('Target resource id to expose privately.')
param targetResourceId string

@description('Group ID — e.g. "account" (Cognitive Services), "vault" (KV), "searchService", "blob".')
param groupId string

@description('Subnet id to host the NIC.')
param subnetResourceId string

@description('Private DNS zone resource ids to register the PE into.')
param privateDnsZoneResourceIds array

@description('Tags.')
param tags object = {}

var dnsZoneConfigs = [for (zoneId, i) in privateDnsZoneResourceIds: {
  name: 'cfg-${i}'
  privateDnsZoneResourceId: zoneId
}]

module pe 'br/public:avm/res/network/private-endpoint:0.10.1' = {
  name: take('pe-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    subnetResourceId: subnetResourceId
    privateLinkServiceConnections: [
      {
        name: '${name}-conn'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [ groupId ]
        }
      }
    ]
    privateDnsZoneGroup: empty(privateDnsZoneResourceIds) ? null : {
      name: 'default'
      privateDnsZoneGroupConfigs: dnsZoneConfigs
    }
  }
}

output peId string = pe.outputs.resourceId
output peName string = pe.outputs.name
