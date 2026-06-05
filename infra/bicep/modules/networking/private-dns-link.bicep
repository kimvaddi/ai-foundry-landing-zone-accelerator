// Cross-RG link from a spoke VNet into an existing private DNS zone.
// Deployed at the zone's host RG via the caller's `scope: resourceGroup(...)`.

@description('DNS zone name (e.g., privatelink.vaultcore.azure.net) — must already exist in this RG.')
param zoneName string

@description('Link name (must be unique within the zone).')
param linkName string

@description('Spoke VNet resource ID.')
param vnetResourceId string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
    registrationEnabled: false
  }
}

output linkId string = link.id
