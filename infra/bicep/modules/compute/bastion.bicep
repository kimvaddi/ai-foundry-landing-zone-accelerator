// =============================================================================
// bastion.bicep — Azure Bastion host (Standard SKU, AzureBastionSubnet-injected)
//
// Companion of the AzureBastionSubnet (/26) created in spoke-vnet.bicep when
// components.bastion.deploy = true. Auto-creates a Standard + Static public IP
// via modules/networking/public-ip.bicep.
// =============================================================================

@description('Bastion host name.')
param name string

@description('Region (same as VNet).')
param location string

@description('Resource ID of the VNet that contains AzureBastionSubnet.')
param vnetResourceId string

@description('Bastion SKU.')
@allowed([ 'Basic', 'Standard', 'Premium' ])
param skuName string = 'Standard'

@description('Enable file copy (Standard/Premium only).')
param enableFileCopy bool = true

@description('Enable IP-connect (Standard/Premium only).')
param enableIpConnect bool = true

@description('Diagnostic LAW workspace resource id.')
param workspaceResourceId string

@description('Tags.')
param tags object = {}

module bastionPip '../networking/public-ip.bicep' = {
  name: take('pip-bastion-${uniqueString(name)}', 64)
  params: {
    name: 'pip-${name}'
    location: location
    tags: tags
    domainNameLabel: toLower('bastion-${uniqueString(name)}')
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.6.1' = {
  name: take('bastion-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    skuName: skuName
    virtualNetworkResourceId: vnetResourceId
    bastionSubnetPublicIpResourceId: bastionPip.outputs.resourceId
    enableFileCopy: skuName == 'Basic' ? false : enableFileCopy
    enableIpConnect: skuName == 'Basic' ? false : enableIpConnect
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        logCategoriesAndGroups: [ { categoryGroup: 'allLogs' } ]
      }
    ]
  }
}

output bastionId    string = bastion.outputs.resourceId
output bastionName  string = bastion.outputs.name
output publicIpId   string = bastionPip.outputs.resourceId
output publicIpFqdn string = bastionPip.outputs.fqdn
