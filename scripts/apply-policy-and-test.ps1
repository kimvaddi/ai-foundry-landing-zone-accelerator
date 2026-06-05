$ErrorActionPreference = 'Stop'
$sub  = '22222222-2222-2222-2222-222222222222'
$rg   = 'rg-klzfin-platform-dev'
$apim = 'apim-klzfin-dev-c6ej'
$apimId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim"
$tok  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$policyXml = Get-Content "$PSScriptRoot\..\apim-policies\inbound-emit-metrics.xml" -Raw

Write-Host '=== Apply fixed global service policy ==='
$body = @{ properties = @{ value = $policyXml; format = 'rawxml' } } | ConvertTo-Json -Depth 10
$url = "https://management.azure.com$apimId/policies/policy?api-version=2024-05-01"
$resp = Invoke-RestMethod -Method Put -Uri $url -Headers @{Authorization="Bearer $tok"; 'Content-Type'='application/json'} -Body $body
Write-Host "  PUT policy: OK (format=$($resp.properties.format))" -ForegroundColor Green

Write-Host ''
Write-Host '=== Fire single test call ==='
$key = (Invoke-RestMethod -Method Post -Uri "https://management.azure.com$apimId/subscriptions/master/listSecrets?api-version=2024-05-01" -Headers @{Authorization="Bearer $tok"}).primaryKey
$url2 = "https://$apim.azure-api.net/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-08-01-preview"
$body2 = '{"messages":[{"role":"user","content":"Say hi in one word"}],"max_tokens":8,"model":"gpt-4o-mini"}'
$h = @{
    'Ocp-Apim-Subscription-Key' = $key
    'Content-Type'              = 'application/json'
    'x-project'                 = 'smoke-after-fix'
    'x-use-case'                = 'workbook-smoke'
    'x-cost-center'             = 'CC-9999'
}
try {
    $r = Invoke-RestMethod -Method Post -Uri $url2 -Headers $h -Body $body2
    Write-Host "  CONTENT: $($r.choices[0].message.content)" -ForegroundColor Green
    Write-Host "  USAGE:   in=$($r.usage.prompt_tokens) out=$($r.usage.completion_tokens) total=$($r.usage.total_tokens)" -ForegroundColor Green
    Write-Host "  MODEL:   $($r.model)" -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
}
