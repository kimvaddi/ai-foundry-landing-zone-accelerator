// =====================================================================
// hub-peering.bicep — Spoke-to-hub VNet peering
//
// Creates the spoke → hub peer. The reverse hub → spoke peer is OPTIONAL
// (requires write perms on the hub RG, often a different subscription).
// When `createReversePeer = false` (default), the caller is responsible
// for creating the hub → spoke peer out-of-band.
//
// Cross-subscription support: when hubVnetResourceId points at a different
// sub, the reverse peer would need a nested `Microsoft.Resources/deployments`
// scoped to the hub's sub/RG. We defer that to a follow-up — Stage A only
// supports same-sub reverse peering.
// =====================================================================

@description('Spoke VNet name (in current RG).')
param spokeVnetName string

@description('Full resource ID of the hub VNet (may be in a different RG or subscription).')
param hubVnetResourceId string

@description('Friendly name suffix for the spoke→hub peer (peer name will be `peer-to-hub-<suffix>`).')
param peerNameSuffix string = 'hub'

@description('Allow traffic from peered network to flow into the spoke.')
param allowVirtualNetworkAccess bool = true

@description('Allow forwarded traffic (NVA scenarios). Required when forced tunneling through hub firewall.')
param allowForwardedTraffic bool = true

@description('Whether the spoke can use the hub gateway (VPN/ER). Set true only when the hub has a gateway AND useRemoteGateways=true on the spoke side.')
param allowGatewayTransit bool = false

@description('Whether this spoke uses the hub\'s gateway for on-prem connectivity. Requires the hub to be configured for gateway transit.')
param useRemoteGateways bool = false

@description('Create the reverse hub→spoke peer. Only works when hub is same-sub and you have write perms on the hub RG.')
param createReversePeer bool = false

// ----------------------- Parse hub resource ID -------------------------
// Hub resource ID format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>
var hubSegments = split(hubVnetResourceId, '/')
var hubSubscriptionId = length(hubSegments) >= 3 ? hubSegments[2] : subscription().subscriptionId
var hubResourceGroup  = length(hubSegments) >= 5 ? hubSegments[4] : resourceGroup().name
var hubVnetName       = length(hubSegments) >= 9 ? hubSegments[8] : ''

// ----------------------- Spoke → hub peer ------------------------------

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: spokeVnetName
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: spokeVnet
  name: 'peer-to-${peerNameSuffix}'
  properties: {
    allowVirtualNetworkAccess: allowVirtualNetworkAccess
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: false
    useRemoteGateways: useRemoteGateways
    remoteVirtualNetwork: {
      id: hubVnetResourceId
    }
  }
}

// ----------------------- Hub → spoke peer (optional, same-sub only) ---

module reversePeer 'hub-peering-reverse.bicep' = if (createReversePeer && hubSubscriptionId == subscription().subscriptionId) {
  name: take('hub-rev-${uniqueString(spokeVnetName, hubVnetName)}', 64)
  scope: resourceGroup(hubResourceGroup)
  params: {
    hubVnetName: hubVnetName
    spokeVnetResourceId: spokeVnet.id
    peerName: 'peer-from-${spokeVnetName}'
    allowVirtualNetworkAccess: allowVirtualNetworkAccess
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: false
  }
  dependsOn: [
    spokeToHub
  ]
}

output spokeToHubPeerId string = spokeToHub.id
output reversePeerAttempted bool = createReversePeer && hubSubscriptionId == subscription().subscriptionId
