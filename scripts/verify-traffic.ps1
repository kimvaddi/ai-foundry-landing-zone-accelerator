$ErrorActionPreference = 'Stop'
$sub = '22222222-2222-2222-2222-222222222222'
$rg  = 'rg-klzfin-platform-dev'
$law = 'log-klzfin-dev-c6ej'
$appi = 'appi-klzfin-dev-c6ej'
$cust = az monitor log-analytics workspace show -g $rg -n $law --query customerId -o tsv
$appId = az monitor app-insights component show -g $rg -a $appi --query appId -o tsv

Write-Host '=== ApiManagementGatewayLlmLog (last 30m) ===' -ForegroundColor Cyan
$kql1 = @'
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(30m)
| project TimeGenerated, OperationId, ConsumedTokens=TotalTokens, PromptTokens, CompletionTokens,
          DeploymentName, ModelName, ProjectFromHdr = extract("x-project-name: ([^\\s]+)", 1, tostring(RequestHeaders))
| order by TimeGenerated desc
| take 20
'@
az monitor log-analytics query -w $cust --analytics-query $kql1 -o table

Write-Host ''
Write-Host '=== ApiManagementGatewayLogs (last 30m) ===' -ForegroundColor Cyan
$kql2 = @'
ApiManagementGatewayLogs
| where TimeGenerated > ago(30m)
| project TimeGenerated, OperationName, ResponseCode, BackendTime, TotalTime, Url
| order by TimeGenerated desc
| take 10
'@
az monitor log-analytics query -w $cust --analytics-query $kql2 -o table

Write-Host ''
Write-Host '=== AppDependencies (gen_ai + tool spans, last 30m) ===' -ForegroundColor Cyan
$kql3 = @'
AppDependencies
| where TimeGenerated > ago(30m)
| where Name startswith "gen_ai" or Name startswith "tool."
| project TimeGenerated, Name, DurationMs, Success,
          project = tostring(Properties["gen_ai.project"]),
          model   = tostring(Properties["gen_ai.request.model"]),
          kind    = tostring(Properties["span.kind"])
| order by TimeGenerated desc
| take 25
'@
az monitor app-insights query -g $rg -a $appi --analytics-query $kql3 -o table

Write-Host ''
Write-Host '=== Summary by project (workbook source check) ===' -ForegroundColor Cyan
$kql4 = @'
AppDependencies
| where TimeGenerated > ago(30m)
| where Name startswith "gen_ai" or Name startswith "tool."
| extend project = tostring(Properties["gen_ai.project"])
| where isnotempty(project)
| summarize calls = count(), avg_ms = avg(DurationMs) by project, Name
| order by project, Name
'@
az monitor app-insights query -g $rg -a $appi --analytics-query $kql4 -o table
