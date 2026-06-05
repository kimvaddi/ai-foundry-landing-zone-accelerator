// =============================================================================
// KLZ FinOps Accelerator — Container Apps Environment (Phase B.2 + Stage B P5)
// =============================================================================
// Hosts the OTel collector (modules/observability/otel-collector.bicep) AND
// stands in as the generic Container Apps platform for FinOps workloads.
//
// Stage B add-on: optional VNet injection into ContainerAppEnvironmentSubnet,
// with internal-only mode for hub-connected deployments. Keep the legacy
// (subnet-less) path working so the OTel-only deploy still works.
// =============================================================================

@description('Managed Environment resource name.')
param name string

@description('Region; inherited from parent deployment.')
param location string

@description('Log Analytics workspace customer ID (GUID) for log destination.')
param workspaceCustomerId string

@description('Log Analytics workspace primary shared key.')
@secure()
param workspaceSharedKey string

@description('Resource ID of ContainerAppEnvironmentSubnet for VNet injection. Empty = public CAE (legacy behavior).')
param infrastructureSubnetResourceId string = ''

@description('Internal-only load balancer (no public ingress). Honored only when infrastructureSubnetResourceId is non-empty.')
param internal bool = false

@description('Workload profiles. Defaults to a single Consumption profile (no min nodes, no idle cost).')
param workloadProfiles array = [
  {
    name: 'Consumption'
    workloadProfileType: 'Consumption'
  }
]

@description('Common tags.')
param tags object = {}

var vnetInjected = !empty(infrastructureSubnetResourceId)

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, {
    'klz:component': 'container-apps-env'
  })
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspaceCustomerId
        sharedKey: workspaceSharedKey
      }
    }
    zoneRedundant: false
    workloadProfiles: workloadProfiles
    vnetConfiguration: vnetInjected ? {
      infrastructureSubnetId: infrastructureSubnetResourceId
      internal: internal
    } : null
  }
}

output environmentId string = cae.id
output environmentName string = cae.name
output defaultDomain string = cae.properties.defaultDomain
output staticIp string = cae.properties.?staticIp ?? ''
