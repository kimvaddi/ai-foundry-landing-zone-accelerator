// =============================================================================
// hub-bootstrap.bicep — Minimal hub for testing prod-hub-connected blueprint
//
// Subscription-scoped: creates one RG containing:
//   - Hub VNet (10.0.0.0/16) with AzureFirewallSubnet (10.0.0.0/26)
//   - Public IP (Standard, Static)
//   - Firewall Policy (Basic)
//   - Azure Firewall (Basic SKU)
//   - 7 private-DNS zones (each linked to hub VNet) matching the subset
//     referenced by prod-hub-connected.bicepparam
//
// Cost: ~$25/day FW Basic + ~$5/day PIP + ~$1/day PDNS links ≈ $31/day
//
// Outputs feed directly into prod-hub-connected.bicepparam:
//   hubVnetResourceId       → hubVnetResourceId
//   hubFirewallPrivateIp    → hubFirewallPrivateIp
//   existingPrivateDnsZones → existingPrivateDnsZones (object)
// =============================================================================

targetScope = 'subscription'

@description('Workload identifier used in resource names.')
param workload string = 'klzfin'

@description('Environment tag (dev/test/prod). Affects RG name only.')
param env string = 'prod'

@description('Azure region for the hub.')
param location string = 'eastus2'

@description('Hub VNet CIDR. Must NOT overlap with the spoke VNet (default spoke is 10.50.0.0/20).')
param hubAddressSpace string = '10.0.0.0/16'

@description('AzureFirewallSubnet CIDR. Must be /26 or larger and live inside hubAddressSpace.')
param firewallSubnetCidr string = '10.0.0.0/26'

@description('AzureFirewallManagementSubnet CIDR. REQUIRED for Firewall Basic SKU. Must be /26 or larger and live inside hubAddressSpace.')
param firewallManagementSubnetCidr string = '10.0.1.0/26'

@description('Common tags applied to every resource.')
param tags object = {
  workload:  workload
  env:       env
  purpose:   'hub-bootstrap'
  ownedBy:   'klz-accelerator'
}

var rgName = 'rg-${workload}-hub-${env}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: tags
}

module resources 'hub-bootstrap-resources.bicep' = {
  name: 'hub-bootstrap-${env}'
  scope: rg
  params: {
    location:                     location
    workload:                     workload
    env:                          env
    hubAddressSpace:              hubAddressSpace
    firewallSubnetCidr:           firewallSubnetCidr
    firewallManagementSubnetCidr: firewallManagementSubnetCidr
    tags:                         tags
  }
}

output resourceGroupName string         = rg.name
output hubVnetResourceId string         = resources.outputs.hubVnetResourceId
output hubFirewallPrivateIp string      = resources.outputs.hubFirewallPrivateIp
output existingPrivateDnsZones object   = resources.outputs.privateDnsZones
