// Scheduled query alert rules — Fabric tool p95, cost vs quota.
//
// Both rules query the workspace; the cost rule joins ApiManagementGatewayLlmLog
// with PRICING_CL + SUBSCRIPTION_QUOTA_CL. The Fabric rule queries AppTraces
// (App Insights) for spans whose name starts with "tool.fabric".

param location string
param nameSuffix string
param workspaceResourceId string
param tags object = {}

@description('Optional Action Group resource ID. If empty, alert fires without notify (still visible in portal).')
param actionGroupId string = ''

@description('Deploy the cost-vs-quota alert. False in smoke mode (ApiManagementGatewayLlmLog table is APIM-only and KQL validator rejects missing tables).')
param deployCostAlert bool = false

// -----------------------------------------------------------------------
// Alert 1 — Fabric tool span p95 > 3 seconds (the the customer KPI)
// -----------------------------------------------------------------------
resource alertFabricLatency 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'sqr-fabric-p95-${nameSuffix}'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [ workspaceResourceId ]
    targetResourceTypes: [ 'Microsoft.OperationalInsights/workspaces' ]
    criteria: {
      allOf: [
        {
          query: '''
AppDependencies
| where Name startswith "tool.fabric"
| summarize p95 = percentile(DurationMs, 95) by bin(TimeGenerated, 5m)
| where p95 > 3000
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: empty(actionGroupId) ? {} : { actionGroups: [ actionGroupId ] }
    autoMitigate: true
  }
}

// -----------------------------------------------------------------------
// Alert 2 — Project cost > 80% of monthly quota
// -----------------------------------------------------------------------
resource alertCostBudget 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployCostAlert) {
  name: 'sqr-cost-vs-quota-${nameSuffix}'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    scopes: [ workspaceResourceId ]
    targetResourceTypes: [ 'Microsoft.OperationalInsights/workspaces' ]
    criteria: {
      allOf: [
        {
          query: '''
let monthStart = startofmonth(now());
let prices = PRICING_CL
| summarize arg_max(TimeGenerated, *) by Model, Region;
let quotas = SUBSCRIPTION_QUOTA_CL
| summarize arg_max(TimeGenerated, *) by SubscriptionId, ProjectName;
union isfuzzy=true ApiManagementGatewayLlmLog
| where TimeGenerated >= monthStart
| extend Body = parse_json(tostring(column_ifexists("BackendResponseBody", "")))
| extend ProjectName = tostring(Body["project"]), SubscriptionId = tostring(Body["subscription_id"])
| extend ModelName = tostring(column_ifexists("ModelName", ""))
| extend PromptTokens = tolong(column_ifexists("PromptTokens", 0))
| extend CompletionTokens = tolong(column_ifexists("CompletionTokens", 0))
| join kind=leftouter prices on $left.ModelName == $right.Model
| extend cost = (PromptTokens/1000.0)*InputPricePer1KTokens + (CompletionTokens/1000.0)*OutputPricePer1KTokens
| summarize MTDCost = sum(cost) by SubscriptionId, ProjectName
| join kind=leftouter quotas on SubscriptionId, ProjectName
| extend PctOfQuota = (MTDCost / MonthlyQuotaUsd) * 100
| where PctOfQuota >= 80
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: empty(actionGroupId) ? {} : { actionGroups: [ actionGroupId ] }
    autoMitigate: false
  }
}

output fabricAlertId string = alertFabricLatency.id
output costAlertId string = deployCostAlert ? alertCostBudget.id : ''
