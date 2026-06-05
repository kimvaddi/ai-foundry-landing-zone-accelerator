// =====================================================================
// route-table.bicep — Forced-tunnel UDR for spoke workload subnets
//
// Stage A behavior: hub-connected mode. UDR with 0.0.0.0/0 → VirtualAppliance
// (next-hop = hub firewall private IP) attached to workload subnets EXCEPT
// AzureFirewallSubnet, AzureBastionSubnet, PrivateEndpointSubnet (these
// either reject UDRs entirely or break PaaS control planes when forced).
//
// Standalone-with-firewall mode is deferred (dependency cycle requires
// staged two-pass deploy; tracked in plan.md P1 follow-up).
// =====================================================================

@description('Route table name.')
param name string

@description('Region.')
param location string

@description('Tags.')
param tags object = {}

@description('Next-hop IP address (hub firewall private IP for hub-connected mode).')
param nextHopIpAddress string

@description('Disable Internet route propagation from BGP. Default true (forced tunneling).')
param disableBgpRoutePropagation bool = true

module rt 'br/public:avm/res/network/route-table:0.5.0' = {
  name: take('rt-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    disableBgpRoutePropagation: disableBgpRoutePropagation
    routes: [
      {
        name: 'default-to-hub-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIpAddress
        }
      }
    ]
  }
}

// Attach the route table to each workload subnet via subnet-update pattern.
// NOTE: we read the existing subnet (which already carries NSG + delegation +
// addressPrefix from spoke-vnet.bicep's second-pass attach) and re-emit it
// with `routeTable.id` added. ARM merges by full property replacement, so we
// must echo every preserved property here.
//
// To keep this module loose-coupled from spoke-vnet internals we accept the
// subnet name list and look up each subnet via `existing` — we DO NOT echo
// addressPrefix/NSG/delegation here (Bicep doesn't expose them at compile
// time from an `existing` ref). Instead we use a child-resource PATCH-style
// pattern: a thin sub-resource that only sets `routeTable`. ARM's behavior
// when you redeploy a subnet child without addressPrefix is to REJECT the
// request — so this approach won't work.
//
// Workaround used: caller (main.bicep) calls a single helper module that
// composes subnet props and routeTable.id together. For Stage A we expose
// the route-table ID and let `spoke-vnet.bicep` v2 (Stage A.1, follow-up)
// thread it into the subnet-attach loop. For now this module ONLY creates
// the route table; attachment is handled in main.bicep using the same
// `Microsoft.Network/virtualNetworks/subnets` pattern as the NSG attach.

output routeTableId string = rt.outputs.resourceId
output routeTableName string = rt.outputs.name
