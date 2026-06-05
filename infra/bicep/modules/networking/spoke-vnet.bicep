// =====================================================================
// spoke-vnet.bicep — Foundry landing zone spoke VNet
//
// Replaces the legacy `vnet.bicep` (single-VNet, 3 hard-coded subnets,
// buggy cidrSubnet calls). Implements the upstream tf-team subnet
// catalog with each subnet gated by a toggle.
//
// Subnet catalog (alphabetical, deterministic order):
//   AIFoundrySubnet                  always   /24  delegated Microsoft.App/environments
//   APIMSubnet                       toggle   /26  optional delegation Microsoft.Web/hostingEnvironments
//   AppGatewaySubnet                 toggle   /24
//   AzureBastionSubnet               toggle   /26  no NSG (Bastion-managed)
//   AzureFirewallSubnet              toggle   /26  no NSG (rejected by ARM)
//   ContainerAppEnvironmentSubnet    toggle   /23  delegated Microsoft.App/environments
//   DevOpsBuildSubnet                toggle   /26
//   JumpboxSubnet                    toggle   /26
//   PrivateEndpointSubnet            always   /24  privateEndpointNetworkPolicies=Disabled
//
// CIDR plan from /20 default (10.50.0.0/20):
//   See `subnetCatalog` below for full layout. Reserved 10.50.6.64+ for growth.
// =====================================================================

@description('VNet name.')
param name string

@description('Region for the VNet.')
param location string

@description('Address space CIDR. Default /20 leaves growth room and fits all 9 subnets with reserved space.')
param addressPrefix string = '10.50.0.0/20'

@description('Tags.')
param tags object = {}

@description('Log Analytics workspace for NSG/VNet diagnostics.')
param workspaceResourceId string

@description('Component toggles. Each toggle gates whether its corresponding subnet is created.')
param components object = {
  bastion:           { deploy: false }
  jumpvm:            { deploy: false }
  buildvm:           { deploy: false }
  appGateway:        { deploy: false }
  containerAppsEnv:  { deploy: false }
  apim:              { deploy: false, networkMode: 'none' }
}

@description('When true, lock down the PrivateEndpointSubnet so only APIM (and explicitly-allowed exceptions) can reach Foundry/Search/KV private endpoints. Requires apim.deploy=true AND apim.networkMode in {external,internal}. Flips PE subnet privateEndpointNetworkPolicies to NetworkSecurityGroupEnabled so NSG rules actually filter PE traffic. Defaults to false to preserve dev-friendly behavior.')
param enforceApimChokepoint bool = false

@description('When chokepoint is on, also allow ContainerAppEnvironmentSubnet to reach private endpoints. Useful when CAE-hosted agent runtimes call Foundry directly (instead of going through APIM). Defaults to false — APIM-only.')
param allowCaeBypass bool = false

@description('When chokepoint is on AND Foundry agent injection is enabled, allow AIFoundrySubnet -> PE inbound. Required for agents to call Foundry/Search/KV. Defaults to true; set false only if agent injection is off.')
param allowAgentSubnetBypass bool = true

// ----------------------- Subnet catalog --------------------------------
// Each entry: enabled, prefix, optional delegation, optional flags.
// `items()` returns alphabetical key order; we rely on that ordering for
// the NSG / subnet for-loops below.

var apimWantsSubnet = contains(components, 'apim') && components.apim.deploy && contains(components.apim, 'networkMode') && components.apim.networkMode != 'none'

var subnetCatalog = {
  AIFoundrySubnet: {
    enabled: true
    addressPrefix: cidrSubnet(addressPrefix, 24, 1)   // 10.50.1.0/24 from /20 (newCIDR=24, not bits-added)
    // For Foundry Standard Agent Service network injection (capabilityHosts with
    // customerSubnet), Azure creates a service association link (legionservicelink)
    // on the subnet that requires Microsoft.App/environments delegation. ARM rejects
    // attempts to remove the delegation while the link exists.
    delegation: 'Microsoft.App/environments'
    attachNsg: true
    privateEndpointNetworkPolicies: 'Disabled'
  }
  APIMSubnet: {
    enabled: apimWantsSubnet
    addressPrefix: cidrSubnet(addressPrefix, 26, 20)  // 10.50.5.0/26 from /20
    // APIM v2 VNet delegation matrix:
    //   StandardV2 (outbound VNet integration only)  -> Microsoft.Web/serverFarms
    //   Premium    (classic VNet injection)          -> no delegation
    //   BasicV2 / public                             -> no subnet (not honored)
    // Premium v2 (injection, `Microsoft.Web/hostingEnvironments`) is not yet
    // exposed by AVM apim 0.9.1; revisit when AVM upgrades.
    delegation: contains(components, 'apim') && contains(components.apim, 'sku') && startsWith(components.apim.sku, 'StandardV2') ? 'Microsoft.Web/serverFarms' : ''
    attachNsg: true
  }
  AppGatewaySubnet: {
    enabled: contains(components, 'appGateway') && components.appGateway.deploy
    addressPrefix: cidrSubnet(addressPrefix, 24, 4)   // 10.50.4.0/24
    delegation: ''
    attachNsg: true
    // Application Gateway v2 SKU requires inbound 65200-65535 from GatewayManager
    // for backend health probes / control-plane traffic; an NSG that blocks these
    // ports causes ApplicationGatewaySubnetInboundTrafficBlockedByNetworkSecurityGroup.
    // Also allow Azure Load Balancer health probes inbound (recommended for AppGW v2).
    securityRules: [
      {
        name: 'Allow-GatewayManager-65200-65535-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
          description: 'AppGW v2 management plane (required by ARM)'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'AppGW v2 health probes from Azure LB'
        }
      }
    ]
  }
  AzureBastionSubnet: {
    enabled: contains(components, 'bastion') && components.bastion.deploy
    addressPrefix: cidrSubnet(addressPrefix, 26, 23)  // 10.50.5.192/26
    delegation: ''
    // Stage A: skip NSG. Bastion runs without one; hardening is a Stage B follow-up.
    attachNsg: false
  }
  AzureFirewallSubnet: {
    enabled: false   // Stage A: standalone-with-firewall deferred. Always disabled for now.
    addressPrefix: cidrSubnet(addressPrefix, 26, 24)  // 10.50.6.0/26 (reserved when disabled)
    delegation: ''
    attachNsg: false // ARM rejects NSG on AzureFirewallSubnet
  }
  ContainerAppEnvironmentSubnet: {
    enabled: contains(components, 'containerAppsEnv') && components.containerAppsEnv.deploy
    addressPrefix: cidrSubnet(addressPrefix, 23, 1)   // 10.50.2.0/23 (CAE recommends /23+)
    delegation: 'Microsoft.App/environments'
    attachNsg: true
  }
  DevOpsBuildSubnet: {
    enabled: contains(components, 'buildvm') && components.buildvm.deploy
    addressPrefix: cidrSubnet(addressPrefix, 26, 21)  // 10.50.5.64/26
    delegation: ''
    attachNsg: true
  }
  JumpboxSubnet: {
    enabled: contains(components, 'jumpvm') && components.jumpvm.deploy
    addressPrefix: cidrSubnet(addressPrefix, 26, 22)  // 10.50.5.128/26
    delegation: ''
    attachNsg: true
  }
  PrivateEndpointSubnet: {
    enabled: true
    addressPrefix: cidrSubnet(addressPrefix, 24, 0)   // 10.50.0.0/24
    delegation: ''
    attachNsg: true
    // When chokepoint enforced, flip to NetworkSecurityGroupEnabled so NSGs
    // actually filter PE traffic. The legacy 'Disabled' value lets all traffic
    // through regardless of NSG (faster but no isolation).
    privateEndpointNetworkPolicies: enforceApimChokepoint ? 'NetworkSecurityGroupEnabled' : 'Disabled'
    securityRules: enforceApimChokepoint ? union(
      [
        {
          name: 'Allow-APIM-To-PrivateEndpoints-443'
          properties: {
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: cidrSubnet(addressPrefix, 26, 20)
            sourcePortRange: '*'
            destinationAddressPrefix: cidrSubnet(addressPrefix, 24, 0)
            destinationPortRange: '443'
            description: 'APIMSubnet -> PE subnet (the only client allowed by default when chokepoint is enforced)'
          }
        }
        {
          name: 'Allow-AzureLoadBalancer-Inbound'
          properties: {
            priority: 110
            direction: 'Inbound'
            access: 'Allow'
            protocol: '*'
            sourceAddressPrefix: 'AzureLoadBalancer'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
            description: 'PE health probes from Azure Load Balancer'
          }
        }
      ],
      allowAgentSubnetBypass ? [
        {
          name: 'Allow-AIFoundryAgentSubnet-To-PrivateEndpoints-443'
          properties: {
            priority: 120
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: cidrSubnet(addressPrefix, 24, 1)
            sourcePortRange: '*'
            destinationAddressPrefix: cidrSubnet(addressPrefix, 24, 0)
            destinationPortRange: '443'
            description: 'EXCEPTION: Foundry Agent Service (network-injected) must reach Foundry/Search PE directly. Set allowAgentSubnetBypass=false to remove.'
          }
        }
      ] : [],
      allowCaeBypass ? [
        {
          name: 'Allow-ContainerAppsEnv-To-PrivateEndpoints-443'
          properties: {
            priority: 130
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            sourceAddressPrefix: cidrSubnet(addressPrefix, 23, 1)
            sourcePortRange: '*'
            destinationAddressPrefix: cidrSubnet(addressPrefix, 24, 0)
            destinationPortRange: '443'
            description: 'EXCEPTION: CAE-hosted agent runtimes call Foundry directly. Off by default; set allowCaeBypass=true to enable.'
          }
        }
      ] : [],
      [
        {
          name: 'Deny-AllOther-Inbound'
          properties: {
            priority: 4096
            direction: 'Inbound'
            access: 'Deny'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
            description: 'Explicit deny — chokepoint guarantee. Azure default DenyAllInbound is 65500 but explicit beats implicit.'
          }
        }
      ]
    ) : []
  }
}

// items(obj) returns [{ key, value }, ...] alphabetically by key.
var allEntries = items(subnetCatalog)
var enabledEntries = filter(allEntries, e => e.value.enabled)
var nsgEntries = filter(enabledEntries, e => e.value.attachNsg)

// ----------------------- NSG-per-subnet --------------------------------

module nsgs 'br/public:avm/res/network/network-security-group:0.5.1' = [for entry in nsgEntries: {
  name: take('nsg-${toLower(entry.key)}-${uniqueString(name)}', 64)
  params: {
    name: 'nsg-${name}-${toLower(entry.key)}'
    location: location
    tags: tags
    securityRules: entry.value.?securityRules ?? []
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        logCategoriesAndGroups: [ { categoryGroup: 'allLogs' } ]
      }
    ]
  }
}]

// ----------------------- VNet + subnets --------------------------------
// Build the subnets array deterministically using the same ordering used for NSGs.
// NSG IDs are matched by NAME via an inline scan to avoid index-skew if a non-NSG
// subnet sits between two NSG subnets in alphabetical order.

var subnetsForVnet = [for entry in enabledEntries: union(
  {
    name: entry.key
    addressPrefix: entry.value.addressPrefix
  },
  empty(entry.value.delegation) ? {} : { delegation: entry.value.delegation },
  contains(entry.value, 'privateEndpointNetworkPolicies') ? { privateEndpointNetworkPolicies: entry.value.privateEndpointNetworkPolicies } : {}
)]

module vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: take('vnet-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [ addressPrefix ]
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        metricCategories: [ { category: 'AllMetrics' } ]
      }
    ]
    subnets: subnetsForVnet
  }
}

// After the VNet exists, attach NSGs in a second pass so we avoid the
// "subnet-NSG reference cycle" some AVM versions hit when you try to embed
// the NSG ID directly in the subnets array of the first pass.
// We attach via the child-resource pattern using `existing` references.

resource vnetExisting 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: name
  dependsOn: [
    vnet
  ]
}

// One subnet-attach per NSG entry. Uses parent: with `existing` VNet.
// Each iteration carries through the full subnet props so we don't drop
// delegation / privateEndpointNetworkPolicies on the round-trip.
//
// @batchSize(1) serializes the loop so we never trigger two concurrent
// PATCHes against the same parent VNet (Azure Network RP responds with
// AnotherOperationInProgress when it sees parallel mutations).
@batchSize(1)
resource subnetNsgAttach 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = [for (entry, idx) in nsgEntries: {
  parent: vnetExisting
  name: entry.key
  properties: {
    addressPrefix: entry.value.addressPrefix
    networkSecurityGroup: {
      id: nsgs[idx].outputs.resourceId
    }
    delegations: empty(entry.value.delegation) ? [] : [
      {
        name: 'delegation'
        properties: {
          serviceName: entry.value.delegation
        }
      }
    ]
    privateEndpointNetworkPolicies: entry.value.?privateEndpointNetworkPolicies ?? 'Enabled'
  }
}]

// ----------------------- Outputs (map-keyed, not index-based) ----------

output vnetId   string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name

// subnetIds: { <SubnetName>: <ResourceId> } — caller uses by name.
// We synthesize IDs from the VNet name + subnet name (more reliable than
// indexing into vnet.outputs.subnetResourceIds, especially with conditionals).
output subnetIds object = reduce(
  enabledEntries,
  {},
  (acc, entry) => union(acc, { '${entry.key}': resourceId('Microsoft.Network/virtualNetworks/subnets', name, entry.key) })
)

// enabledSubnets: array of subnet names actually deployed (helps callers gate UDR attachment, PE creation, etc.).
output enabledSubnets array = map(enabledEntries, e => e.key)

// addressSpace: echo back for downstream peering modules.
output addressPrefix string = addressPrefix
