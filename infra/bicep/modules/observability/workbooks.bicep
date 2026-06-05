// Workbook deployments — Agent Performance + FinOps Showback.
//
// Workbooks are stored as serialized JSON in the .json files next to this
// module; we load them via loadTextContent() and deploy a workbook resource
// scoped to the LAW (so they show under Monitor > Workbooks).

param location string
param workspaceResourceId string
@description('App Insights resource ID — reserved for future workbook variants that query the AI resource directly instead of the workspace.')
#disable-next-line no-unused-params
param appInsightsResourceId string
param tags object = {}

// -----------------------------------------------------------------------
// Agent performance workbook (latency, tool spans, model usage)
//
// sourceId is the LAW (not the App Insights component) because the queries
// use workspace-based table names (AppDependencies, AppExceptions). App
// Insights is wired in workspace-based mode (IngestionMode=LogAnalytics)
// so its telemetry lands in the LAW under the App* prefixed tables; the
// classic 'dependencies' / 'exceptions' names only resolve when querying
// the App Insights resource directly.
// -----------------------------------------------------------------------
resource wbAgentPerf 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(workspaceResourceId, 'wb-agent-perf')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Foundry — Agent Performance & Tool Latency'
    serializedData: loadTextContent('../../../../observability/workbooks/agent-performance.json')
    version: '1.0'
    sourceId: workspaceResourceId
    category: 'workbook'
  }
}

// -----------------------------------------------------------------------
// FinOps showback workbook (cost per subscription/project)
// -----------------------------------------------------------------------
resource wbFinOps 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(workspaceResourceId, 'wb-finops-showback')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Foundry — FinOps Showback'
    serializedData: loadTextContent('../../../../observability/workbooks/finops-showback.json')
    version: '1.0'
    sourceId: workspaceResourceId
    category: 'workbook'
  }
}

output agentPerfWorkbookId string = wbAgentPerf.id
output finOpsWorkbookId string = wbFinOps.id
