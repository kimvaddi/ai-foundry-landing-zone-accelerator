// Hub → spoke reverse peer. Deployed at hub RG scope.
// Caller (hub-peering.bicep) gates this on same-subscription + createReversePeer=true.

@description('Hub VNet name (must exist in the deployment scope RG).')
param hubVnetName string

@description('Full resource ID of the spoke VNet.')
param spokeVnetResourceId string

@description('Peer name on the hub side.')
param peerName string

param allowVirtualNetworkAccess bool = true
param allowForwardedTraffic bool = true
param allowGatewayTransit bool = false
param useRemoteGateways bool = false

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: hubVnetName
}

resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hubVnet
  name: peerName
  properties: {
    allowVirtualNetworkAccess: allowVirtualNetworkAccess
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
    remoteVirtualNetwork: {
      id: spokeVnetResourceId
    }
  }
}

output peerId string = hubToSpoke.id
