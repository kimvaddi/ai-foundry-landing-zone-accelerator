// Foundry account = Microsoft.CognitiveServices/accounts kind=AIServices.
//
// Per repo memory: tenant policies frequently force disableLocalAuth=true,
// so we set it true here and surface MI as the canonical auth path. This
// also means the AVM module's listKeys output is skipped.

@description('Cog services / Foundry account name.')
@maxLength(64)
param name string
param location string
param workspaceResourceId string
param tags object = {}

@description('Allow projects to be created under this account.')
param allowProjectManagement bool = true

@description('System-assigned MI is enabled by default for downstream auth.')
param identityType string = 'SystemAssigned'

@description('Model deployments to attach.')
param modelDeployments array = []

@description('Foundry projects to create as child resources. Each item: { name, displayName, description }')
param projects array = []

@description('Stage B P2: Per-project BYOR connections (flat list). Each entry: { projectName, name, category, target, authType?=AAD, metadata?, isSharedToAll?=true }. Categories: CognitiveSearch | AzureBlob | AzureKeyVault | CosmosDb | Custom. AAD requires the project MI to have the appropriate role on the target.')
param byorConnections array = []

@description('Stage B P3: When non-empty AND a BYOR connection of category=CognitiveSearch has an empty target, auto-fill the connection target to this endpoint.')
param defaultSearchEndpoint string = ''

@description('Whether to disable local-auth (key-based). Set true for enterprise; honors tenant policy.')
param disableLocalAuth bool = true

@description('Public network access. Default Enabled to keep current behavior; set Disabled when PE is the only ingress and you trust upstream networkAcls.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('Stage B P2: Standard Agent Service VNet injection. When non-empty, registers the AIFoundrySubnet on the account so Foundry creates a managed CAE inside the subnet for agent workloads. Subnet must be delegated to Microsoft.App/environments.')
param agentSubnetResourceId string = ''

@description('Stage B P2: When true, create a `Microsoft.CognitiveServices/accounts/capabilityHosts` resource (kind=Agents) on the account. Pair with agentSubnetResourceId for the Standard Agent Service.')
param createAccountCapabilityHost bool = false

@description('Name of the account-level capability host. Default deterministic from account name.')
param accountCapabilityHostName string = ''

var customSubDomain = toLower(replace(name, '_', '-'))
var hasAgentInjection = !empty(agentSubnetResourceId)
var capabilityHostName = empty(accountCapabilityHostName) ? 'caphost-${take(uniqueString(name), 8)}' : accountCapabilityHostName

module account 'br/public:avm/res/cognitive-services/account:0.14.2' = {
  name: take('aif-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    kind: 'AIServices'
    sku: 'S0'
    customSubDomainName: customSubDomain
    allowProjectManagement: allowProjectManagement
    disableLocalAuth: disableLocalAuth
    publicNetworkAccess: publicNetworkAccess
    managedIdentities: {
      systemAssigned: identityType == 'SystemAssigned' || identityType == 'SystemAssigned,UserAssigned'
    }
    deployments: modelDeployments
    networkInjections: hasAgentInjection ? {
      scenario: 'agent'
      subnetResourceId: agentSubnetResourceId
      useMicrosoftManagedNetwork: false
    } : null
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        logCategoriesAndGroups: [ { categoryGroup: 'allLogs' } ]
        metricCategories: [ { category: 'AllMetrics' } ]
      }
    ]
  }
}

// Foundry projects as child resources (not yet first-class in AVM module)
resource accountRef 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: name
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = [for p in projects: {
  parent: accountRef
  name: p.name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: p.displayName
    description: p.description
  }
  dependsOn: [
    account
  ]
}]

// ---------------------------------------------------------------------------
// Stage B P2: Account-level capability host (Standard Agent Service)
// Per rubber-duck #3: networkInjections alone is necessary but not sufficient
// for parity with the upstream landing zone — capabilityHosts complete the
// agent service wiring.
// ---------------------------------------------------------------------------
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = if (createAccountCapabilityHost) {
  parent: accountRef
  name: capabilityHostName
  properties: union(
    {
      capabilityHostKind: 'Agents'
    },
    empty(agentSubnetResourceId) ? {} : {
      // Must match the subnet recorded on the Foundry account's networkInjections,
      // otherwise ARM returns: "The customerSubnet property must match the subnet
      // recorded on the Foundry account."
      customerSubnet: agentSubnetResourceId
    }
  )
  dependsOn: [
    account
  ]
}

// ---------------------------------------------------------------------------
// Stage B P2 + P3: Per-project BYOR connections (flat array; one resource per entry).
// `byorConnections` is a flat top-level array (Bicep does not allow nested for-loops),
// each entry: { projectName, name, category, target, authType?='AAD', metadata?, isSharedToAll?=true }
// CognitiveSearch entries with empty target auto-fill to `defaultSearchEndpoint` when provided.
// AAD auth requires the corresponding project MI to have the appropriate role on the target.
// ---------------------------------------------------------------------------
resource projectConnections 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = [for c in byorConnections: {
  name: '${name}/${c.projectName}/${c.name}'
  properties: {
    category: c.category
    target: (c.category == 'CognitiveSearch' && empty(c.?target ?? '') && !empty(defaultSearchEndpoint)) ? defaultSearchEndpoint : c.target
    authType: c.?authType ?? 'AAD'
    isSharedToAll: c.?isSharedToAll ?? true
    metadata: c.?metadata ?? {}
  }
  dependsOn: [
    project
  ]
}]

// Note: project-level capabilityHosts (`Microsoft.CognitiveServices/accounts/projects/capabilityHosts`)
// use a different schema than the account level — they require `aiServicesConnections`,
// `storageConnections`, `threadStorageConnections`, `vectorStoreConnections` (arrays of
// connection IDs). Wiring that requires the connections to be created first, then a
// second-pass module to wire them into the project capability host. Out of scope for the
// initial p2-foundry land; add as a follow-up once connection IDs are exposed as outputs.

output resourceId string = account.outputs.resourceId
output endpoint string = account.outputs.endpoint
output principalId string = account.outputs.?systemAssignedMIPrincipalId ?? ''
output projectIds array = [for (p, i) in projects: project[i].id]
output projectPrincipalIds array = [for (p, i) in projects: project[i].identity.principalId]
output agentInjectionConfigured bool = hasAgentInjection
output capabilityHostName string = createAccountCapabilityHost ? capabilityHostName : ''
