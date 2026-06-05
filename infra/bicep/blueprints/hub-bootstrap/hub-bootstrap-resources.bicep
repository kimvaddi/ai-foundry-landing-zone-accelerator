// =============================================================================
// hub-bootstrap-resources.bicep — RG-scoped resources for the hub.
// Consumed by hub-bootstrap.bicep (subscription-scoped).
// =============================================================================

targetScope = 'resourceGroup'

param location string
param workload string
param env string
param hubAddressSpace string
param firewallSubnetCidr string
param firewallManagementSubnetCidr string
param tags object

var nameSuffix = '${workload}-${env}'

// ---------------------------------------------------------------------------
// Hub VNet
// ---------------------------------------------------------------------------

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-hub-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ hubAddressSpace ] }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnetCidr
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: firewallManagementSubnetCidr
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Firewall public IP
// ---------------------------------------------------------------------------

resource fwPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-fw-${nameSuffix}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion:   'IPv4'
  }
}

resource fwMgmtPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-fw-mgmt-${nameSuffix}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion:   'IPv4'
  }
}

// ---------------------------------------------------------------------------
// Firewall policy (Basic)
// ---------------------------------------------------------------------------

resource fwPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'fwpol-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Basic' }
    threatIntelMode: 'Alert'
  }
}

// ---------------------------------------------------------------------------
// Azure Firewall (Basic SKU)
// Basic requires a management IP / management subnet for some scenarios,
// but the simplest deployable shape uses a single data-plane IP and the
// classic 'AzureFirewallSubnet'. We deploy without management IP for cost.
// ---------------------------------------------------------------------------

resource fwSubnetRef 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: hubVnet
  name:   'AzureFirewallSubnet'
}

resource fwMgmtSubnetRef 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: hubVnet
  name:   'AzureFirewallManagementSubnet'
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: 'fw-${nameSuffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Basic' }
    firewallPolicy: { id: fwPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipcfg'
        properties: {
          subnet:          { id: fwSubnetRef.id }
          publicIPAddress: { id: fwPip.id }
        }
      }
    ]
    managementIpConfiguration: {
      name: 'fw-mgmt-ipcfg'
      properties: {
        subnet:          { id: fwMgmtSubnetRef.id }
        publicIPAddress: { id: fwMgmtPip.id }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Private DNS zones (subset referenced by prod-hub-connected blueprint)
// Each linked to the hub VNet.
// ---------------------------------------------------------------------------

var privateDnsZoneNames = [
  'privatelink.vaultcore.azure.net'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.azure-api.net'
  'privatelink.documents.azure.com'
]

resource pdnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in privateDnsZoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]

resource pdnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in privateDnsZoneNames: {
  name: '${zone}/link-to-hub'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
  dependsOn: [ pdnsZones[i] ]
}]

// ---------------------------------------------------------------------------
// Outputs (keyed map matches the spoke param schema)
// ---------------------------------------------------------------------------

output hubVnetResourceId string    = hubVnet.id
output hubFirewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress

output privateDnsZones object = {
  vaultcore:         pdnsZones[0].id
  openai:            pdnsZones[1].id
  cognitiveServices: pdnsZones[2].id
  search:            pdnsZones[3].id
  blob:              pdnsZones[4].id
  apim:              pdnsZones[5].id
  cosmosSql:         pdnsZones[6].id
}
