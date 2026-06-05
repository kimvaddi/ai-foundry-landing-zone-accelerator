// Log Analytics workspace — AVM wrapper, retains 30 days, daily cap 1 GB for smoke.
@description('Workspace name.')
param name string
param location string
param tags object = {}

@description('Daily ingestion cap in GB (-1 for none). Cheap smoke = 1.')
param dailyQuotaGb int = 1

@description('Retention in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

module workspace 'br/public:avm/res/operational-insights/workspace:0.15.1' = {
  name: take('law-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dailyQuotaGb: string(dailyQuotaGb)
    dataRetention: retentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Existing reference so we can fetch listKeys() — needed only by callers that
// host a Container Apps Environment for the OTel collector (Phase B.2). The
// explicit dependsOn forces ARM to evaluate this AFTER the AVM workspace
// module finishes provisioning, avoiding the ResourceNotFound race we
// previously observed during fast end-to-end deploys.
resource workspaceExisting 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: name
  dependsOn: [
    workspace
  ]
}

output workspaceName string = workspace.outputs.name
output workspaceResourceId string = workspace.outputs.resourceId
output workspaceCustomerId string = workspace.outputs.logAnalyticsWorkspaceId

@secure()
output workspaceSharedKey string = workspaceExisting.listKeys().primarySharedKey
