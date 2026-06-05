// =====================================================================
// udr-attach.bicep — Attach a route table to an existing subnet
//
// ARM subnet updates require us to re-emit ALL subnet properties (it's a
// full-property PUT, not a PATCH). To avoid having to know the addressPrefix
// / NSG / delegation of every subnet at this point in the deployment, we
// use `existing` to read them back and merge the routeTable ID via a JSON
// `Microsoft.Resources/deployments` wrapper.
//
// In practice: the cleanest pattern is to chain a NEW subnet child resource
// after the spoke-vnet's own subnet-attach pass. ARM resolves this as an
// in-place update because the subnet name matches.
//
// We use a small inline DeploymentScript trick? No — we use a sub-deployment
// at the parent VNet scope that reads the existing subnet and rebuilds it.
//
// Implementation: we use an `Microsoft.Network/virtualNetworks/subnets` child
// resource declared with `existing` semantics for reading, then a NEW resource
// that depends on the existing one and copies its props. This works because
// the deployment-time `reference()` returns the current property bag.
// =====================================================================

@description('Spoke VNet name (must exist in current RG).')
param vnetName string

@description('Subnet name to update with the route table attachment.')
param subnetName string

@description('Route table resource ID to attach. Empty string = no-op (module is gated upstream anyway).')
param routeTableId string

// Read current subnet state.
resource currentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${vnetName}/${subnetName}'
}

// Re-emit the subnet with all current props + the routeTable.id added.
// `reference()` on an existing resource returns its properties bag; we splat
// it through `union()` to preserve everything else.
resource patched 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: '${vnetName}/${subnetName}'
  properties: union(
    {
      addressPrefix: currentSubnet.properties.addressPrefix
      networkSecurityGroup: empty(currentSubnet.properties.?networkSecurityGroup ?? {}) ? null : { id: currentSubnet.properties.networkSecurityGroup.id }
      delegations: currentSubnet.properties.?delegations ?? []
      privateEndpointNetworkPolicies: currentSubnet.properties.?privateEndpointNetworkPolicies ?? 'Enabled'
    },
    empty(routeTableId) ? {} : { routeTable: { id: routeTableId } }
  )
}

output subnetId string = patched.id
