// =====================================================================
// main.bicep — Foundry Enterprise Landing Zone + FinOps (subscription scope)
//
// Stage A scope (this revision):
//   • New networking model: networkMode = standalone | hub-connected
//   • 9-subnet catalog gated by `components` toggles (default 8 active)
//   • 21 private DNS zones (create-or-reference based on networkMode)
//   • Always-on baseline: PrivateEndpointSubnet + AIFoundrySubnet
//
// Toggles defined but not yet wired (Stage B work):
//   • components.bastion / .jumpvm / .buildvm / .appGateway / .containerAppsEnv
//     → subnets ARE created when their toggle flips on, but the compute
//        resources (Bastion host, VMs, AppGW, CAE) are not deployed yet.
//   • APIM SKU widening + VNet injection
//   • Foundry multi-project + agent network injection + BYOR
//
// Deploy
//   az deployment sub create --location eastus2 \
//     --template-file infra/bicep/main.bicep \
//     --parameters infra/bicep/parameters/quickstart-standalone.bicepparam
// =====================================================================

targetScope = 'subscription'

// ----------------------- Identity / metadata --------------------------

@description('Workload short name, used in naming. Lower-case, 3-8 chars.')
@minLength(3)
@maxLength(8)
param workload string = 'klzfin'

@description('Environment label (dev|test|prod).')
@allowed([ 'dev', 'test', 'prod', 'smoke', 'poc', 'sandbox' ])
param env string = 'dev'

@description('Primary location for all resources.')
param location string = 'eastus2'

@description('Override location for AI Search (capacity in eastus2 is constrained; westus2 often has headroom).')
param searchLocation string = location

@description('Tags applied to every resource.')
param tags object = {
  workload: workload
  env: env
  owner: 'platform-team'
  costCenter: 'AI-Platform'
  managedBy: 'klz-accelerator-finops'
}

// ----------------------- Component toggles ----------------------------

@description('Networking mode. standalone = no FW, no hub (create our own DNS). hub-connected = peer to BYO hub (reference existing DNS). standalone-with-firewall is a Stage B follow-up.')
@allowed([ 'standalone', 'hub-connected' ])
param networkMode string = 'hub-connected'

@description('Component toggles. Each gates its subnet creation; compute deploy follows in Stage B.')
param components object = {
  bastion:          { deploy: false, sku: 'Standard' }
  jumpvm:           { deploy: false, sku: 'Standard_B2s' }
  buildvm:          { deploy: false, sku: 'Standard_B2s' }
  appGateway:       { deploy: false, wafEnabled: true, sku: 'WAF_v2' }
  containerAppsEnv: { deploy: false }
  apim:             { deploy: true, sku: 'StandardV2', networkMode: 'none' }
  standaloneSearch: { deploy: true, sku: 'basic' }
  notifications:    { deploy: false }
  otelCollector:    { deploy: false }
}

// ----------------------- Networking config ----------------------------

@description('VNet address space CIDR. Default /20 fits all 9 subnets with growth room.')
param vnetAddressSpace string = '10.50.0.0/20'

@description('Hub VNet resource ID — REQUIRED when networkMode=hub-connected. Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>')
param hubVnetResourceId string = ''

@description('Hub firewall private IP (next-hop for forced-tunnel UDR). When empty, no UDR is created.')
param hubFirewallPrivateIp string = ''

@description('Enable forced tunneling (0/0 → hub FW). Only honored when hub-connected AND hubFirewallPrivateIp is set. Set false to bring up hub-connected mode without forced tunneling (initial bring-up).')
param enableForcedTunneling bool = true

@description('Also create the reverse hub→spoke peer. Requires write perms on hub RG. Only works for same-subscription hubs in this revision.')
param createReverseHubPeer bool = false

@description('When networkMode=hub-connected, map of zoneFriendlyName→resourceId for existing private DNS zones living in the hub. See modules/networking/private-dns.bicep zoneCatalog for friendly keys.')
param existingPrivateDnsZones object = {}

// ----------------------- AI Gateway chokepoint -----------------------

@description('When true, APIM AI Gateway becomes the single chokepoint for all Foundry / Search / KV data-plane traffic. Flips Foundry+Search publicNetworkAccess to Disabled, enables NSG enforcement on the PrivateEndpointSubnet, and allows only APIMSubnet (and explicitly-opted exceptions) to reach the PEs. Requires apim.deploy=true AND apim.networkMode in {external,internal}. Defaults to false so smoke / POC dry-runs work without VNet line-of-sight.')
param enforceApimChokepoint bool = false

@description('When chokepoint is on, also allow ContainerAppEnvironmentSubnet → PE inbound (lets CAE-hosted agent runtimes call Foundry directly, bypassing APIM). Off by default — keep APIM as the only path.')
param allowCaeBypass bool = false

@description('When chokepoint is on AND Foundry agent injection is enabled, allow AIFoundrySubnet → PE inbound. Required for the Standard Agent Service to reach Foundry/Search PEs. On by default; safe to leave on even without agent injection (rule has no effect when subnet is empty).')
param allowAgentSubnetBypass bool = true

// ----------------------- AI platform ----------------------------------

@description('Models to deploy on the Foundry account.')
param modelDeployments array = [
  {
    name: 'gpt-4o-mini'
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
    sku: { name: 'GlobalStandard', capacity: 10 }
  }
]

@description('Foundry projects to create as child resources.')
param foundryProjects array = [
  {
    name: 'default'
    displayName: 'Default project'
    description: 'Created by klz-accelerator-finops'
  }
]

@description('Stage B P2: Per-project BYOR connections (flat list). Each entry: { projectName, name, category, target, authType?=AAD, metadata?, isSharedToAll?=true }. Categories: CognitiveSearch | AzureBlob | AzureKeyVault | CosmosDb | Custom.')
param foundryByorConnections array = []

@description('Stage B P2: When true, register the AIFoundrySubnet on the Foundry account as the Standard Agent Service network injection point. Independent of components.containerAppsEnv.deploy — Foundry creates its own managed CAE inside the subnet for agents.')
param enableFoundryAgentInjection bool = false

@description('Stage B P2: When true, also create an account-level capability host (kind=Agents). Required for the Standard Agent Service to host agents. Implies enableFoundryAgentInjection should also be true.')
param createFoundryCapabilityHost bool = false

@description('Stage B P3: When true AND components.standaloneSearch.deploy=true AND a BYOR connection of category=CognitiveSearch has an empty target, auto-fill the target to the standalone Search service endpoint. Saves operator from copy-pasting the search endpoint.')
param autoWireSearchConnection bool = true

// ----------------------- Notifications / OTel -------------------------

@description('Deploy the Phase B.4 Logic App notification stub. Ships in state=Disabled regardless.')
param deployNotifications bool = false

@description('When deployNotifications=true, flip the Logic App workflow state to Enabled.')
param enableNotificationsLogicApp bool = false

@description('Incoming Webhook URL for a Teams channel. SecureString — never written to logs.')
@secure()
param teamsWebhookUrl string = ''

@description('Optional comma-separated fallback email list for the notifications workflow.')
param notificationEmails string = ''

@description('Optional secondary OTLP endpoint (gRPC) for the OTel collector.')
param otelSecondaryEndpoint string = ''

// ----------------------- Compute toggle credentials -------------------
// Required only when the corresponding toggle is on. Provide via Key Vault
// reference in your bicepparam (`adminPassword: kv.getSecret('jumpvm-pwd')`).

@description('Windows admin password for the jumpbox VM. REQUIRED when components.jumpvm.deploy=true. Pass via Key Vault getSecret().')
@secure()
param jumpvmAdminPassword string = ''

@description('SSH public key (OpenSSH single-line format) for the build-agent VM. REQUIRED when components.buildvm.deploy=true.')
param buildvmSshPublicKey string = ''

@description('Internal-only Container Apps Environment. Recommended for hub-connected mode so ingress stays inside the VNet.')
param containerAppsEnvInternal bool = true

// ----------------------- APIM publisher contact -----------------------

@description('APIM publisher contact local-part (left of @).')
param apimPublisherLocalPart string = 'platform'

@description('APIM publisher contact domain (right of @). Not validated for ownership.')
param apimPublisherDomain string = 'klzfin.com'

@description('APIM publisher display name.')
param apimPublisherName string = 'KLZ FinOps Platform'

// ----------------------- AI Gateway safety + cache toggles -----------

@description('Enable Azure AI Content Safety category scoring (Hate/Sexual/Violence/SelfHarm) on the APIM AI API. Adds llm-content-safety policy element.')
param enableContentSafety bool = false

@description('Enable Prompt Shields jailbreak detection on the APIM AI API. Combined with enableContentSafety into the same llm-content-safety element.')
param enablePromptShields bool = false

@description('Content Safety severity threshold (FourSeverityLevels: 0/2/4/6). 4 = block medium+ severity.')
@allowed([ 0, 2, 4, 6 ])
param safetyThreshold int = 4

@description('Enable APIM semantic cache. Provisions Redis Enterprise (RediSearch) + APIM external cache + embeddings backend.')
param enableSemanticCache bool = false

@description('Embedding deployment name used by the semantic cache lookup policy. Must be deployed on the Foundry account.')
param embeddingsDeploymentName string = 'text-embedding-3-large'

@description('Per-product TPM cap for the APIM `foundry-default` product. Templated into product-token-limit.xml.')
param apimProductTokensPerMinute int = 50000

// ----------------------- Post-deploy RBAC (Microsoft Foundry guidance) -----
// Wires up the recommended role-assignment model from
//   https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry
// Default OFF — every existing deployment is unaffected unless the operator
// opts in by setting enablePostDeployRbac=true AND providing object IDs.
// Each role assignment is gated by `empty()` on its principal, so partial
// configurations are valid (e.g. wire only the admin group).

@description('Master switch for the post-deploy RBAC module. When false (default), no role assignments are emitted regardless of the object IDs below.')
param enablePostDeployRbac bool = false

@description('Entra group object ID -> Foundry Owner on the Foundry account. Highly privileged. Leave empty to skip.')
param foundryAdminGroupObjectId string = ''

@description('Entra group object ID -> Foundry Project Manager on the Foundry account (team leads who publish agents and create projects). Leave empty to skip.')
param foundryLeadGroupObjectId string = ''

@description('Entra group object ID -> Foundry User on the Foundry account (developers who build agents and call models). Leave empty to skip.')
param foundryDeveloperGroupObjectId string = ''

@description('Entra group object ID -> Reader on the platform RG (auditors / SREs / FinOps). Leave empty to skip.')
param platformReaderGroupObjectId string = ''

@description('Entra group object ID -> Reader on the Foundry account (Foundry-only auditors / read-only data scientists). Leave empty to skip. If omitted but platformReaderGroupObjectId is set, the platform reader group is reused for Foundry Reader for backward compatibility.')
param foundryReaderGroupObjectId string = ''

@description('Service principal object ID -> Contributor on the platform RG (CI/CD pipelines that deploy workloads). Leave empty to skip.')
param deploymentSpnObjectId string = ''

var apimPublisherEmail = '${apimPublisherLocalPart}@${apimPublisherDomain}'

// ----------------------- Naming ---------------------------------------

var nameSuffix = '${workload}-${env}-${take(uniqueString(subscription().id, workload, env), 4)}'

var rgPlatformName = 'rg-${workload}-platform-${env}'
var rgFoundryName  = 'rg-${workload}-foundry-${env}'

// ----------------------- Validation guards ----------------------------
// Fail-fast at compile when hub-connected mode is selected without hub inputs.
// Bicep `assert` is GA — emits a deployment-time error if the condition is false.

@description('Validation: hub-connected mode requires hubVnetResourceId.')
output _validation_hubVnet string = (networkMode == 'hub-connected' && empty(hubVnetResourceId))
  ? 'ERROR: networkMode=hub-connected requires hubVnetResourceId. Set in your bicepparam.'
  : 'OK'

@description('Validation: forced tunneling requires hubFirewallPrivateIp when enabled.')
output _validation_forcedTunnel string = (enableForcedTunneling && networkMode == 'hub-connected' && empty(hubFirewallPrivateIp))
  ? 'WARN: enableForcedTunneling=true but hubFirewallPrivateIp is empty — UDR will NOT be created. Set hubFirewallPrivateIp or set enableForcedTunneling=false.'
  : 'OK'

@description('Validation: chokepoint requires APIM deployed AND APIM in VNet (external or internal).')
output _validation_chokepointApim string = (enforceApimChokepoint && (!components.apim.deploy || (contains(components.apim, 'networkMode') ? components.apim.networkMode == 'none' : true)))
  ? 'ERROR: enforceApimChokepoint=true requires components.apim.deploy=true AND components.apim.networkMode in {external,internal}. APIM must be VNet-integrated to reach private Foundry/Search.'
  : 'OK'

@description('Validation: chokepoint + standalone Search requires the search to be in the same region (so a PE can be attached).')
output _validation_chokepointSearchRegion string = (enforceApimChokepoint && components.standaloneSearch.deploy && searchLocation != location)
  ? 'ERROR: enforceApimChokepoint=true with standaloneSearch.deploy=true requires searchLocation == location (PE cannot be cross-region). Either disable standalone search, move it to the VNet region, or set enforceApimChokepoint=false.'
  : 'OK'

@description('Info: when chokepoint is on with agent injection, the AIFoundrySubnet -> PE rule is auto-added as a documented exception.')
output _info_chokepointAgentBypass string = (enforceApimChokepoint && enableFoundryAgentInjection && allowAgentSubnetBypass)
  ? 'INFO: Foundry Agent Service is on — AIFoundrySubnet is allowed to reach the PE subnet. APIM is the chokepoint for *external* clients; agents go direct.'
  : 'OK'

// ----------------------- Resource Groups ------------------------------

resource rgPlatform 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgPlatformName
  location: location
  tags: tags
}

resource rgFoundry 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgFoundryName
  location: location
  tags: tags
}

// ----------------------- Foundation -----------------------------------

module law 'modules/foundation/log-analytics.bicep' = {
  scope: rgPlatform
  name: 'law-${env}'
  params: {
    name: 'log-${nameSuffix}'
    location: location
    tags: tags
  }
}

module appInsights 'modules/foundation/app-insights.bicep' = {
  scope: rgPlatform
  name: 'appi-${env}'
  params: {
    name: 'appi-${nameSuffix}'
    location: location
    workspaceResourceId: law.outputs.workspaceResourceId
    tags: tags
  }
}

module keyVault 'modules/foundation/key-vault.bicep' = {
  scope: rgPlatform
  name: 'kv-${env}'
  params: {
    name: 'kv-${nameSuffix}'
    location: location
    workspaceResourceId: law.outputs.workspaceResourceId
    tags: tags
  }
}

// ----------------------- AI platform ----------------------------------

// Stage B P3: Default search endpoint for auto-wiring CognitiveSearch BYOR connections.
// The foundry module will substitute this for any BYOR connection with empty target + category=CognitiveSearch.
var defaultSearchEndpoint = (components.standaloneSearch.deploy && autoWireSearchConnection) ? 'https://srch-${nameSuffix}.search.windows.net' : ''

module foundry 'modules/ai-platform/foundry-account.bicep' = {
  scope: rgFoundry
  name: 'foundry-${env}'
  params: {
    name: 'aif-${nameSuffix}'
    location: location
    workspaceResourceId: law.outputs.workspaceResourceId
    modelDeployments: modelDeployments
    projects: foundryProjects
    byorConnections: foundryByorConnections
    defaultSearchEndpoint: defaultSearchEndpoint
    agentSubnetResourceId: enableFoundryAgentInjection ? spokeVnet.outputs.subnetIds.AIFoundrySubnet : ''
    createAccountCapabilityHost: createFoundryCapabilityHost
    publicNetworkAccess: enforceApimChokepoint ? 'Disabled' : 'Enabled'
    tags: tags
  }
}

module aiSearch 'modules/ai-platform/ai-search.bicep' = if (components.standaloneSearch.deploy) {
  scope: rgFoundry
  name: 'search-${env}'
  params: {
    name: 'srch-${nameSuffix}'
    location: searchLocation
    workspaceResourceId: law.outputs.workspaceResourceId
    publicNetworkAccess: enforceApimChokepoint ? 'Disabled' : 'Enabled'
    disableLocalAuth: enforceApimChokepoint
    tags: tags
  }
}

// ----------------------- FinOps ---------------------------------------

module finops 'modules/finops/custom-tables.bicep' = {
  scope: rgPlatform
  name: 'finops-${env}'
  params: {
    workspaceName: law.outputs.workspaceName
    workspaceResourceId: law.outputs.workspaceResourceId
    location: location
    tags: tags
  }
}

// ----------------------- Observability --------------------------------

module workbooks 'modules/observability/workbooks.bicep' = {
  scope: rgPlatform
  name: 'wb-${env}'
  params: {
    location: location
    workspaceResourceId: law.outputs.workspaceResourceId
    appInsightsResourceId: appInsights.outputs.resourceId
    tags: tags
  }
}

module alerts 'modules/observability/alerts.bicep' = {
  scope: rgPlatform
  name: 'alerts-${env}'
  params: {
    location: location
    nameSuffix: nameSuffix
    workspaceResourceId: law.outputs.workspaceResourceId
    tags: tags
    // Cost-vs-quota alert queries ApiManagementGatewayLlmLog which only exists
    // when APIM is deployed. Skip the cost rule when APIM is off.
    deployCostAlert: components.apim.deploy
  }
}

// ----------------------- Networking (always on) -----------------------
// Spoke VNet is always created. Subnet contents driven by `components` + `networkMode`.

module spokeVnet 'modules/networking/spoke-vnet.bicep' = {
  scope: rgPlatform
  name: 'vnet-${env}'
  params: {
    name: 'vnet-${nameSuffix}'
    location: location
    addressPrefix: vnetAddressSpace
    workspaceResourceId: law.outputs.workspaceResourceId
    components: components
    enforceApimChokepoint: enforceApimChokepoint
    allowCaeBypass: allowCaeBypass
    allowAgentSubnetBypass: allowAgentSubnetBypass
    tags: tags
  }
}

// Hub peering — only when hub-connected AND a hub ID was provided.
module hubPeering 'modules/networking/hub-peering.bicep' = if (networkMode == 'hub-connected' && !empty(hubVnetResourceId)) {
  scope: rgPlatform
  name: 'hub-peer-${env}'
  params: {
    spokeVnetName: spokeVnet.outputs.vnetName
    hubVnetResourceId: hubVnetResourceId
    peerNameSuffix: 'hub'
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false
    createReversePeer: createReverseHubPeer
  }
}

// Route table — only when hub-connected AND forced tunneling on AND a FW IP given.
var udrShouldDeploy = networkMode == 'hub-connected' && enableForcedTunneling && !empty(hubFirewallPrivateIp)

module routeTable 'modules/networking/route-table.bicep' = if (udrShouldDeploy) {
  scope: rgPlatform
  name: 'rt-${env}'
  params: {
    name: 'rt-${nameSuffix}'
    location: location
    nextHopIpAddress: hubFirewallPrivateIp
    tags: tags
  }
}

// Subnets that get the forced-tunnel UDR attached. Excludes special subnets:
//   AzureFirewallSubnet (we don't own one in hub-connected mode anyway),
//   AzureBastionSubnet (rejects UDR by ARM contract),
//   PrivateEndpointSubnet (UDR breaks PE → service routing in many cases).
//
// Bicep requires for-expression iterables to be resolvable at compile time, so
// we cannot iterate over `spokeVnet.outputs.enabledSubnets`. Instead we re-derive
// the udr-attachable subnet list from the SAME `components` toggles that drive
// spoke-vnet.bicep — keep these two lists in sync if subnet logic changes.
var udrCandidateSubnets = concat(
  [ 'AIFoundrySubnet' ], // always-on workload subnet
  components.apim.deploy && components.apim.networkMode != 'none' ? [ 'APIMSubnet' ] : [],
  components.appGateway.deploy ? [ 'AppGatewaySubnet' ] : [],
  components.containerAppsEnv.deploy ? [ 'ContainerAppEnvironmentSubnet' ] : [],
  components.buildvm.deploy ? [ 'DevOpsBuildSubnet' ] : [],
  components.jumpvm.deploy ? [ 'JumpboxSubnet' ] : []
)

// Attach the route table to each udr-attachable subnet via subnet PATCH.
// Per-subnet sub-deployment so we can resolve subnetIds map by name safely.
module udrAttach 'modules/networking/udr-attach.bicep' = [for subnetName in udrCandidateSubnets: if (udrShouldDeploy) {
  scope: rgPlatform
  name: 'udr-${take(toLower(subnetName), 24)}-${env}'
  params: {
    vnetName: spokeVnet.outputs.vnetName
    subnetName: subnetName
    routeTableId: udrShouldDeploy ? routeTable!.outputs.routeTableId : ''
  }
}]

// Private DNS — create-or-reference based on networkMode.
module privateDns 'modules/networking/private-dns.bicep' = {
  scope: rgPlatform
  name: 'pdns-${env}'
  params: {
    vnetResourceId: spokeVnet.outputs.vnetId
    createZones: networkMode == 'standalone'
    existingZones: existingPrivateDnsZones
    linkExistingZonesToSpoke: true
    tags: tags
  }
}

// ----------------------- Private Endpoints ----------------------------
// PEs for Foundry + KV always created (we always have a PE subnet + DNS zones).
// Search PE only when standaloneSearch is deployed AND in same region as VNet
// (cross-region PE not supported).

module peFoundry 'modules/networking/private-endpoint.bicep' = {
  scope: rgFoundry
  name: 'pe-foundry-${env}'
  params: {
    name: 'pe-aif-${nameSuffix}'
    location: location
    targetResourceId: foundry.outputs.resourceId
    groupId: 'account'
    subnetResourceId: spokeVnet.outputs.subnetIds.PrivateEndpointSubnet
    // Foundry kind=AIServices registers into BOTH cognitiveservices + openai zones.
    privateDnsZoneResourceIds: empty(privateDns.outputs.zoneIds.cognitiveServices) ? [] : [
      privateDns.outputs.zoneIds.cognitiveServices
      privateDns.outputs.zoneIds.openai
    ]
    tags: tags
  }
}

module peKeyVault 'modules/networking/private-endpoint.bicep' = {
  scope: rgPlatform
  name: 'pe-kv-${env}'
  params: {
    name: 'pe-kv-${nameSuffix}'
    location: location
    targetResourceId: keyVault.outputs.resourceId
    groupId: 'vault'
    subnetResourceId: spokeVnet.outputs.subnetIds.PrivateEndpointSubnet
    privateDnsZoneResourceIds: empty(privateDns.outputs.zoneIds.vaultcore) ? [] : [
      privateDns.outputs.zoneIds.vaultcore
    ]
    tags: tags
  }
}

module peSearch 'modules/networking/private-endpoint.bicep' = if (components.standaloneSearch.deploy && searchLocation == location) {
  scope: rgFoundry
  name: 'pe-search-${env}'
  params: {
    name: 'pe-srch-${nameSuffix}'
    location: location
    targetResourceId: components.standaloneSearch.deploy ? aiSearch!.outputs.resourceId : ''
    groupId: 'searchService'
    subnetResourceId: spokeVnet.outputs.subnetIds.PrivateEndpointSubnet
    privateDnsZoneResourceIds: empty(privateDns.outputs.zoneIds.search) ? [] : [
      privateDns.outputs.zoneIds.search
    ]
    tags: tags
  }
}

// ----------------------- AI Gateway / APIM ----------------------------

// Redis Enterprise — backing store for APIM semantic cache. Only deployed
// when enableSemanticCache=true. Adds ~$8.6/day (E10).
// The connection string is written to a Key Vault secret to avoid BCP426
// (secure outputs can't cross conditional-module boundaries).
var keyVaultNameLocal = 'kv-${nameSuffix}'

module redisCache 'modules/ai-platform/redis-enterprise.bicep' = if (enableSemanticCache) {
  scope: rgPlatform
  name: 'redis-${env}'
  params: {
    name: 'rec-${nameSuffix}'
    location: location
    tags: tags
    keyVaultName: keyVaultNameLocal
    secretName: 'redis-connection-string'
  }
  dependsOn: [
    keyVault
  ]
}

// `existing` reference for KV-getSecret pattern (only used when semantic cache on).
resource kvForRedis 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultNameLocal
  scope: rgPlatform
}

// APIM VNet injection (Stage B): when components.apim.networkMode in {external, internal},
// pass the APIMSubnet from the spoke + (external only) an optional pre-created Public IP id.
// If networkMode='external' but no PIP id supplied, we synthesize a Public IP in this RG so
// the deploy is one-shot. Internal mode skips the PIP entirely.

var apimNetworkMode = contains(components, 'apim') && contains(components.apim, 'networkMode') ? components.apim.networkMode : 'none'
var apimSku         = contains(components, 'apim') && contains(components.apim, 'sku')         ? components.apim.sku         : 'StandardV2'
var apimWantsVnet   = components.apim.deploy && apimNetworkMode != 'none'

// Auto-create a Public IP for external mode if the caller didn't bring one.
var apimPipNameAuto = 'pip-apim-${nameSuffix}'
module apimPip 'modules/networking/public-ip.bicep' = if (apimWantsVnet && apimNetworkMode == 'external') {
  scope: rgPlatform
  name: 'pip-apim-${env}'
  params: {
    name: apimPipNameAuto
    location: location
    tags: tags
    // APIM v2 requires Standard + Static + DNS label so the gateway hostname resolves
    domainNameLabel: toLower('apim-${nameSuffix}')
  }
}

module apim 'modules/ai-gateway/apim.bicep' = if (components.apim.deploy) {
  scope: rgPlatform
  name: 'apim-${env}'
  params: {
    name: 'apim-${nameSuffix}'
    location: location
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    appInsightsResourceId: appInsights.outputs.resourceId
    appInsightsConnectionString: appInsights.outputs.connectionString
    workspaceResourceId: law.outputs.workspaceResourceId
    sku: apimSku
    networkMode: apimNetworkMode
    subnetResourceId: apimWantsVnet ? spokeVnet.outputs.subnetIds.APIMSubnet : ''
    publicIpResourceId: (apimWantsVnet && apimNetworkMode == 'external') ? apimPip!.outputs.resourceId : ''
    tags: tags
  }
}

module apimAi 'modules/ai-gateway/apim-ai-api.bicep' = if (components.apim.deploy) {
  scope: rgPlatform
  name: 'apim-ai-${env}'
  params: {
    apimName: components.apim.deploy ? apim!.outputs.name : ''
    foundryEndpoint: foundry.outputs.endpoint
    foundryResourceId: foundry.outputs.resourceId
    appInsightsLoggerId: components.apim.deploy ? apim!.outputs.appInsightsLoggerId : ''
    productTokensPerMinute: apimProductTokensPerMinute
    enableContentSafety: enableContentSafety
    enablePromptShields: enablePromptShields
    safetyThreshold: safetyThreshold
    enableSemanticCache: enableSemanticCache
    embeddingsDeploymentName: embeddingsDeploymentName
  }
}

// Wire the APIM external cache to Redis Enterprise. Separate module so the
// secure `connectionString` output can be passed via direct module reference
// (BCP426: ternaries cannot wrap secure outputs).
module apimRedisCache 'modules/ai-gateway/apim-redis-cache.bicep' = if (enableSemanticCache && components.apim.deploy) {
  scope: rgPlatform
  name: 'apim-redis-cache-${env}'
  params: {
    apimName: apim!.outputs.name
    redisConnectionString: kvForRedis.getSecret('redis-connection-string')
  }
  dependsOn: [
    apimAi
    redisCache
  ]
}

module apimFoundryRbac 'modules/ai-gateway/apim-foundry-rbac.bicep' = if (components.apim.deploy) {
  scope: rgFoundry
  name: 'apim-foundry-rbac-${env}'
  params: {
    foundryAccountName: 'aif-${nameSuffix}'
    principalId: components.apim.deploy ? apim!.outputs.principalId : ''
  }
}

// ----------------------- Notifications (opt-in) -----------------------

module notifications 'modules/observability/notifications.bicep' = if (deployNotifications) {
  scope: rgPlatform
  name: 'notif-${env}'
  params: {
    name: 'logic-notif-${nameSuffix}'
    location: location
    tags: tags
    enabled: enableNotificationsLogicApp
    teamsWebhookUrl: teamsWebhookUrl
    notificationEmails: notificationEmails
  }
}

// ----------------------- Container Apps Env + OTel (opt-in) -----------
// CAE deploys when either components.containerAppsEnv.deploy OR components.otelCollector.deploy.
// (Otel needs CAE as a host.)

var deployCae = components.containerAppsEnv.deploy || components.otelCollector.deploy

module containerAppsEnv 'modules/observability/container-apps-env.bicep' = if (deployCae) {
  scope: rgPlatform
  name: 'cae-${env}'
  params: {
    name: 'cae-${nameSuffix}'
    location: location
    workspaceCustomerId: law.outputs.workspaceCustomerId
    workspaceSharedKey: law.outputs.workspaceSharedKey
    // Stage B: VNet-inject when components.containerAppsEnv.deploy is on AND the
    // ContainerAppEnvironmentSubnet exists. OTel-only callers (no containerAppsEnv toggle)
    // still get the legacy public-CAE path.
    infrastructureSubnetResourceId: components.containerAppsEnv.deploy ? spokeVnet.outputs.subnetIds.ContainerAppEnvironmentSubnet : ''
    internal: components.containerAppsEnv.deploy ? containerAppsEnvInternal : false
    tags: tags
  }
}

module otelCollector 'modules/observability/otel-collector.bicep' = if (components.otelCollector.deploy) {
  scope: rgPlatform
  name: 'otel-${env}'
  params: {
    name: 'ca-otel-${nameSuffix}'
    location: location
    environmentId: deployCae ? containerAppsEnv!.outputs.environmentId : ''
    image: 'mcr.microsoft.com/azuremonitor/containerinsights/cidev/applicationinsights-opentelemetry-collector:latest'
    appInsightsConnectionString: appInsights.outputs.connectionString
    secondaryOtlpEndpoint: otelSecondaryEndpoint
    minReplicas: 0
    maxReplicas: 3
    tags: tags
  }
}

// ----------------------- Compute toggles (Stage B) --------------------
// Each gated by its own components.<x>.deploy flag. Subnets for these are
// already created in spoke-vnet.bicep when the toggle is on. Order matters
// only for dependsOn — Bicep handles that via the spokeVnet.outputs references.

module bastion 'modules/compute/bastion.bicep' = if (components.bastion.deploy) {
  scope: rgPlatform
  name: 'bastion-${env}'
  params: {
    name: 'bas-${nameSuffix}'
    location: location
    vnetResourceId: spokeVnet.outputs.vnetId
    skuName: components.bastion.?sku ?? 'Standard'
    workspaceResourceId: law.outputs.workspaceResourceId
    tags: tags
  }
}

module jumpbox 'modules/compute/jumpbox.bicep' = if (components.jumpvm.deploy) {
  scope: rgPlatform
  name: 'jumpvm-${env}'
  params: {
    // Windows VM names are limited to 15 chars. nameSuffix is up to ~13 (workload<=8 + env<=4 + 4-hash);
    // 'jmp-' + suffix can exceed — use a shortened uniqueString instead.
    name: 'jmp-${take(uniqueString(rgPlatform.id, 'jumpvm'), 8)}'
    location: location
    subnetResourceId: spokeVnet.outputs.subnetIds.JumpboxSubnet
    vmSize: components.jumpvm.?sku ?? 'Standard_B2s'
    adminPassword: jumpvmAdminPassword
    tags: tags
  }
}

module buildAgent 'modules/compute/build-agent.bicep' = if (components.buildvm.deploy) {
  scope: rgPlatform
  name: 'buildvm-${env}'
  params: {
    name: 'bld-${nameSuffix}'
    location: location
    subnetResourceId: spokeVnet.outputs.subnetIds.DevOpsBuildSubnet
    vmSize: components.buildvm.?sku ?? 'Standard_B2s'
    sshPublicKey: buildvmSshPublicKey
    tags: tags
  }
}

module appGateway 'modules/compute/app-gateway.bicep' = if (components.appGateway.deploy) {
  scope: rgPlatform
  name: 'appgw-${env}'
  params: {
    name: 'agw-${nameSuffix}'
    location: location
    subnetResourceId: spokeVnet.outputs.subnetIds.AppGatewaySubnet
    // Per rubber-duck #5: WAF_v2 requires firewallPolicy. If wafEnabled=false,
    // downgrade to Standard_v2 to avoid the invalid config.
    skuName: (components.appGateway.?wafEnabled ?? true) ? 'WAF_v2' : 'Standard_v2'
    workspaceResourceId: law.outputs.workspaceResourceId
    tags: tags
  }
}

// ----------------------- Post-deploy RBAC (opt-in) --------------------
// Implements Microsoft Foundry RBAC guidance. Each sub-module gates its
// individual role assignments with empty() checks on principal IDs, so a
// partial configuration (e.g. only admin group provided) is valid.

module postRbacFoundry 'modules/security/rbac-foundry-scope.bicep' = if (enablePostDeployRbac) {
  scope: rgFoundry
  name: 'post-rbac-foundry-${env}'
  params: {
    foundryAccountName: 'aif-${nameSuffix}'
    searchServiceName: components.standaloneSearch.deploy ? 'srch-${nameSuffix}' : ''
    foundryAdminGroupObjectId: foundryAdminGroupObjectId
    foundryLeadGroupObjectId: foundryLeadGroupObjectId
    foundryDeveloperGroupObjectId: foundryDeveloperGroupObjectId
    foundryReaderGroupObjectId: empty(foundryReaderGroupObjectId) ? platformReaderGroupObjectId : foundryReaderGroupObjectId
    foundryAccountPrincipalId: foundry.outputs.principalId
    projectPrincipalIds: foundry.outputs.projectPrincipalIds
  }
  dependsOn: [
    aiSearch
  ]
}

module postRbacPlatform 'modules/security/rbac-platform-scope.bicep' = if (enablePostDeployRbac) {
  scope: rgPlatform
  name: 'post-rbac-platform-${env}'
  params: {
    keyVaultName: 'kv-${nameSuffix}'
    platformReaderGroupObjectId: platformReaderGroupObjectId
    deploymentSpnObjectId: deploymentSpnObjectId
    jumpVmPrincipalId: components.jumpvm.deploy ? jumpbox!.outputs.principalId : ''
    buildVmPrincipalId: components.buildvm.deploy ? buildAgent!.outputs.principalId : ''
  }
}

output workspaceId string = law.outputs.workspaceResourceId
output workspaceCustomerId string = law.outputs.workspaceCustomerId
output appInsightsId string = appInsights.outputs.resourceId
output keyVaultId string = keyVault.outputs.resourceId
output foundryAccountId string = foundry.outputs.resourceId
output foundryEndpoint string = foundry.outputs.endpoint
output searchServiceId string = components.standaloneSearch.deploy ? aiSearch!.outputs.resourceId : ''

// FinOps / Phase B.3 outputs
output dceEndpoint string = finops.outputs.dceEndpoint
output pricingDcrImmutableId string = finops.outputs.pricingDcrImmutableId
output quotaDcrImmutableId string = finops.outputs.quotaDcrImmutableId
output agentAuditDcrImmutableId string = finops.outputs.agentAuditDcrImmutableId
output agentAuditDcrId string = finops.outputs.agentAuditDcrId
output agentAuditStream string = finops.outputs.agentAuditStream

// Networking outputs
output vnetId string = spokeVnet.outputs.vnetId
output vnetName string = spokeVnet.outputs.vnetName
output enabledSubnets array = spokeVnet.outputs.enabledSubnets
output privateDnsZoneIds object = privateDns.outputs.zoneIds
output hubPeerDeployed bool = networkMode == 'hub-connected' && !empty(hubVnetResourceId)
output forcedTunnelingDeployed bool = udrShouldDeploy

// APIM outputs
output apimGatewayUrl string = components.apim.deploy ? apim!.outputs.gatewayUrl : ''
output apimResourceId string = components.apim.deploy ? apim!.outputs.resourceId : ''

// Opt-in outputs
output notificationWorkflowId string = deployNotifications ? notifications!.outputs.workflowId : ''
output notificationWorkflowState string = deployNotifications ? notifications!.outputs.workflowState : 'NotDeployed'
output otelCollectorEnvId string = deployCae ? containerAppsEnv!.outputs.environmentId : ''

// Stage-A metadata
output networkMode string = networkMode
output stageVersion string = 'Stage A - networking refactor (2026-06)'
