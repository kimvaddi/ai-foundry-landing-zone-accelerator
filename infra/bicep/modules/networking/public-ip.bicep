// Public IP — Standard SKU + Static allocation (the only combo APIM v2,
// App Gateway v2, Bastion, and Azure Firewall accept).
//
// Used as a shared helper by ai-gateway/apim.bicep (external mode),
// compute/bastion.bicep, and compute/app-gateway.bicep.

@description('Public IP name. 1-80 chars.')
@maxLength(80)
param name string

@description('Region. Must match the consuming resource.')
param location string

@description('Tags.')
param tags object = {}

@description('DNS label (left of the regional FQDN). Lowercase, 3-63 chars, no special chars. When empty, no DNS label is set.')
param domainNameLabel string = ''

@description('SKU. Standard is required for APIM v2 / AppGW v2 / Bastion / Firewall.')
@allowed([ 'Standard' ])
param sku string = 'Standard'

@description('Allocation method. Static is required for Standard SKU.')
@allowed([ 'Static' ])
param allocationMethod string = 'Static'

@description('Availability zones. Default = none (regional). For zone-redundant deploys, pass [ "1", "2", "3" ].')
param zones array = []

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    tier: 'Regional'
  }
  zones: empty(zones) ? null : zones
  properties: {
    publicIPAllocationMethod: allocationMethod
    publicIPAddressVersion: 'IPv4'
    dnsSettings: empty(domainNameLabel) ? null : {
      domainNameLabel: domainNameLabel
    }
  }
}

output resourceId string = pip.id
output name       string = pip.name
output ipAddress  string = pip.properties.?ipAddress ?? ''
output fqdn       string = pip.properties.dnsSettings.?fqdn ?? ''
