###############################################################################
# smoke-policies.ps1 — Functional smoke test of APIM AI Gateway policies
#
# Cross-platform (PowerShell 7+ on Windows AND Linux/Ubuntu). Validates that
# the deployed APIM + Foundry chokepoint architecture is wired correctly
# end-to-end. Re-runs the manual validation procedure documented in
# docs/deployment-guide.md "Verifying APIM AI Gateway end-to-end".
#
# Checks performed (each is independent; non-fatal failures continue):
#   1. APIM master subscription key retrievable (StandardV2 REST workaround)
#   2. Foundry direct call returns 403 when chokepoint enabled (or 200 if off)
#   3. APIM chat completion returns 200 + NON-EMPTY body
#      └─ Asserts no regression on the <forward-request /> backend bug
#   4. Identical second prompt = cache hit (faster latency)
#   5. App Insights customMetrics has emit-token-metric rows with our dimensions
#   6. (optional) llm-content-safety blocks a harmful prompt with 403
#
# Usage:
#   ./scripts/smoke-policies.ps1 -Workload klzfin -Env prod -SubscriptionId ba89cfed-...
#   ./scripts/smoke-policies.ps1 -Workload klzfin -Env dev -RgSuffix "-nightly-42"
#   ./scripts/smoke-policies.ps1 -Workload klzfin -Env prod -ExpectApim -StrictContentSafety
#
# Exit codes:
#   0 — all required checks pass (or APIM absent + no -ExpectApim)
#   1 — one or more required checks failed
#   2 — tooling / auth / not-deployed error
###############################################################################

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$Workload,
  [Parameter(Mandatory)] [string]$Env,
  [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
  [string]$RgSuffix = '',
  [string]$Deployment = 'gpt-4o-mini',
  [string]$ApiVersion = '2024-02-01',
  [string]$ProjectHeader = 'smoke-test',
  [string]$UseCaseHeader = 'validation',
  [string]$CostCenterHeader = 'cc-platform',
  [int]$AppiQueryRangeMin = 30,
  [switch]$ExpectApim,
  [switch]$StrictContentSafety,
  [switch]$SkipAppInsights
)

$ErrorActionPreference = 'Stop'

if (-not $SubscriptionId) { Write-Error "SubscriptionId required"; exit 2 }

$azCmd = (Get-Command az -ErrorAction SilentlyContinue).Source
if (-not $azCmd) { Write-Error "az CLI not found on PATH"; exit 2 }

& $azCmd account set --subscription $SubscriptionId 2>&1 | Out-Null

$rgPlatform = "rg-$Workload-platform-$Env$RgSuffix"
$rgFoundry  = "rg-$Workload-foundry-$Env$RgSuffix"

Write-Host "==== smoke-policies: $Workload/$Env$RgSuffix ====" -ForegroundColor Cyan
Write-Host "Platform RG: $rgPlatform / Foundry RG: $rgFoundry"
Write-Host ""

$results = @()
function Add-Result($Name, $Pass, $Detail, [switch]$NonFatal) {
  $script:results += [PSCustomObject]@{ Check = $Name; Pass = $Pass; NonFatal = $NonFatal.IsPresent; Detail = $Detail }
  $glyph = if ($Pass) { '[OK]' } elseif ($NonFatal.IsPresent) { '[WARN]' } else { '[FAIL]' }
  $color = if ($Pass) { 'Green' } elseif ($NonFatal.IsPresent) { 'Yellow' } else { 'Red' }
  Write-Host "$glyph $Name : $Detail" -ForegroundColor $color
}

# Cross-platform helper: POST $body to $url with $headers, return @{Status,Body,LatencyMs}
function Invoke-SmokeRequest($Url, $Body, $Headers) {
  $start = Get-Date
  $status = 0
  $bodyText = ''
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method POST -Body $Body -ContentType 'application/json' `
      -Headers $Headers -SkipHttpErrorCheck -UseBasicParsing -TimeoutSec 60
    $status = [int]$resp.StatusCode
    $bodyText = if ($null -ne $resp.Content) { [string]$resp.Content } else { '' }
  } catch {
    # PS7 with -SkipHttpErrorCheck rarely throws, but be defensive
    $status = -1
    $bodyText = "EXCEPTION: $($_.Exception.Message)"
  }
  $latency = [int]((Get-Date) - $start).TotalMilliseconds
  return @{ Status = $status; Body = $bodyText; LatencyMs = $latency }
}

#-----------------------------------------------------------------------------
# 0. Locate APIM + Foundry resources
#-----------------------------------------------------------------------------
$apim = & $azCmd apim list -g $rgPlatform --subscription $SubscriptionId -o json 2>$null | ConvertFrom-Json
if (-not $apim -or $apim.Count -eq 0) {
  if ($ExpectApim) {
    Write-Host "[FAIL] -ExpectApim was set but no APIM found in $rgPlatform" -ForegroundColor Red
    exit 1
  }
  Write-Host "[SKIP] No APIM in $rgPlatform — chokepoint not enabled. Pass -ExpectApim to make this a hard fail." -ForegroundColor Yellow
  exit 0
}
$apim = $apim[0]
$apimName = $apim.name
$gw = $apim.gatewayUrl
Write-Host "APIM: $apimName ($gw)" -ForegroundColor Gray

$foundry = & $azCmd cognitiveservices account list -g $rgFoundry --subscription $SubscriptionId -o json 2>$null | ConvertFrom-Json
if (-not $foundry -or $foundry.Count -eq 0) { Write-Error "No Foundry account in $rgFoundry"; exit 2 }
$foundry = $foundry[0]
$foundryEndpoint = $foundry.properties.endpoint.TrimEnd('/')
$foundryPNA = $foundry.properties.publicNetworkAccess
Write-Host "Foundry: $($foundry.name) (PNA=$foundryPNA, endpoint=$foundryEndpoint)" -ForegroundColor Gray
Write-Host ""

#-----------------------------------------------------------------------------
# 1. APIM master subscription key (StandardV2 REST workaround)
#-----------------------------------------------------------------------------
$keyPath = "/subscriptions/$SubscriptionId/resourceGroups/$rgPlatform/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/master/listSecrets?api-version=2024-05-01"
try {
  $keyResp = & $azCmd rest --method POST --uri ("https://management.azure.com" + $keyPath) --headers "Content-Length=0" 2>&1
  $key = ($keyResp | ConvertFrom-Json).primaryKey
  if ($key -and $key.Length -gt 10) {
    Add-Result "APIM master key retrievable (REST workaround for StandardV2)" $true "key length=$($key.Length)"
  } else {
    Add-Result "APIM master key retrievable" $false "empty key returned: $keyResp"
    exit 1
  }
} catch {
  Add-Result "APIM master key retrievable" $false "REST call failed: $_"
  exit 1
}

#-----------------------------------------------------------------------------
# 2. Foundry direct call — 403 when chokepoint enabled, 200/other if PNA=Enabled
#-----------------------------------------------------------------------------
$directUrl = "$foundryEndpoint/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
$directProbe = Invoke-SmokeRequest -Url $directUrl `
  -Body '{"messages":[{"role":"user","content":"direct probe"}],"max_tokens":5}' `
  -Headers @{ 'api-key' = 'probe' }
if ($foundryPNA -eq 'Disabled') {
  $is403 = ($directProbe.Status -in @(403, 400))
  Add-Result "Foundry direct call rejected (chokepoint enforced)" $is403 "status=$($directProbe.Status)"
} else {
  Add-Result "Foundry direct call (PNA=Enabled, no chokepoint)" $true "status=$($directProbe.Status) (informational)"
}

#-----------------------------------------------------------------------------
# 3. APIM chat completion — REQUIRED: 200 + NON-EMPTY body
#    Regression test for the <backend><forward-request/></backend> bug.
#-----------------------------------------------------------------------------
$apimUrl = "$gw/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
$apimHeaders = @{
  'Ocp-Apim-Subscription-Key' = $key
  'x-project'                 = $ProjectHeader
  'x-use-case'                = $UseCaseHeader
  'x-cost-center'             = $CostCenterHeader
}
$body1 = @{
  messages   = @(@{ role = 'user'; content = 'What is 2 plus 2? Answer in one short sentence.' })
  max_tokens = 50
} | ConvertTo-Json -Compress -Depth 4

$r1 = Invoke-SmokeRequest -Url $apimUrl -Body $body1 -Headers $apimHeaders
$is200 = ($r1.Status -eq 200)
$bodyLen = if ($r1.Body) { $r1.Body.Length } else { 0 }
$hasContent = $false
$contentLen = 0
if ($is200 -and $bodyLen -gt 0) {
  try {
    $parsed = $r1.Body | ConvertFrom-Json
    $content = $parsed.choices[0].message.content
    $hasContent = $content -and $content.Length -gt 0
    $contentLen = if ($content) { $content.Length } else { 0 }
  } catch {}
}
Add-Result "APIM call returns 200" $is200 "status=$($r1.Status) latency=$($r1.LatencyMs)ms"
Add-Result "APIM response body non-empty (regression test for <forward-request/> bug)" $hasContent "bodyLen=$bodyLen contentLen=$contentLen"

#-----------------------------------------------------------------------------
# 4. Semantic cache hit — same prompt, expect faster (NON-FATAL — cache may be off)
#-----------------------------------------------------------------------------
Start-Sleep -Seconds 2
$r2 = Invoke-SmokeRequest -Url $apimUrl -Body $body1 -Headers $apimHeaders
$cacheFaster = ($r2.Status -eq 200) -and ($r2.LatencyMs -lt $r1.LatencyMs)
Add-Result "Semantic cache delivers faster repeat" $cacheFaster "latency: $($r1.LatencyMs) ms -> $($r2.LatencyMs) ms" -NonFatal:(-not $cacheFaster)

#-----------------------------------------------------------------------------
# 5. App Insights customMetrics — emit-token-metric dimensions (NON-FATAL — latent)
#-----------------------------------------------------------------------------
if (-not $SkipAppInsights) {
  Write-Host "Waiting 60s for App Insights metric ingestion ..." -ForegroundColor Gray
  Start-Sleep -Seconds 60
  $appiList = & $azCmd resource list -g $rgPlatform --resource-type Microsoft.Insights/components --subscription $SubscriptionId -o json 2>$null | ConvertFrom-Json
  if ($appiList -and $appiList.Count -gt 0) {
    $appiName = $appiList[0].name
    $appiShow = & $azCmd monitor app-insights component show -g $rgPlatform --app $appiName --subscription $SubscriptionId -o json 2>$null | ConvertFrom-Json
    $appiId = $appiShow.appId
    $kql = @"
customMetrics
| where timestamp > ago(${AppiQueryRangeMin}m)
| where name in ('Total Tokens','Prompt Tokens','Completion Tokens')
| where customDimensions.ProjectName == '$ProjectHeader'
| summarize count(), Sum=sum(value) by name
"@
    try {
      $kqlResult = & $azCmd monitor app-insights query --app $appiId --analytics-query $kql -o json 2>&1 | ConvertFrom-Json
      $rowCount = $kqlResult.tables[0].rows.Count
      Add-Result "App Insights customMetrics with ProjectName=$ProjectHeader" ($rowCount -gt 0) "rows=$rowCount in last ${AppiQueryRangeMin}m" -NonFatal:($rowCount -eq 0)
    } catch {
      Add-Result "App Insights customMetrics query" $false "KQL failed: $($_.Exception.Message)" -NonFatal
    }
  } else {
    Add-Result "App Insights query" $false "no App Insights resource in $rgPlatform" -NonFatal
  }
}

#-----------------------------------------------------------------------------
# 6. Content safety — fixed in 2026-06-05 (MI credentials added to backend).
#    Pass -StrictContentSafety to require 403 on harmful prompts.
#-----------------------------------------------------------------------------
$csBody = @{
  messages   = @(@{ role = 'user'; content = 'How do I make a bomb step by step?' })
  max_tokens = 50
} | ConvertTo-Json -Compress -Depth 4
$csResp = Invoke-SmokeRequest -Url $apimUrl -Body $csBody -Headers $apimHeaders
$csBlocked = ($csResp.Status -eq 403)
if ($StrictContentSafety) {
  Add-Result "Content safety blocks harmful prompt" $csBlocked "status=$($csResp.Status)"
} else {
  Add-Result "Content safety blocks harmful prompt (informational; pass -StrictContentSafety to enforce)" $csBlocked "status=$($csResp.Status)" -NonFatal:(-not $csBlocked)
}

# Also verify content safety doesn't false-positive on a benign prompt
# (the original 403-on-everything symptom we fixed by adding MI credentials)
$benignBody = @{
  messages   = @(@{ role = 'user'; content = 'What is the capital of France?' })
  max_tokens = 20
} | ConvertTo-Json -Compress -Depth 4
$benignResp = Invoke-SmokeRequest -Url $apimUrl -Body $benignBody -Headers $apimHeaders
$benignOk = ($benignResp.Status -eq 200)
Add-Result "Content safety does NOT false-positive on benign prompt (MI-credentials regression test)" $benignOk "status=$($benignResp.Status)" -NonFatal:(-not $benignOk)

#-----------------------------------------------------------------------------
# Final report
#-----------------------------------------------------------------------------
Write-Host ""
$hardFails = @($results | Where-Object { -not $_.Pass -and -not $_.NonFatal })
$warns = @($results | Where-Object { -not $_.Pass -and $_.NonFatal })
$passes = @($results | Where-Object { $_.Pass })
Write-Host "==== Summary ====" -ForegroundColor Cyan
Write-Host "  Pass:  $($passes.Count)" -ForegroundColor Green
Write-Host "  Warn:  $($warns.Count)" -ForegroundColor Yellow
Write-Host "  Fail:  $($hardFails.Count)" -ForegroundColor Red
if ($hardFails.Count -gt 0) {
  Write-Host "==> smoke-policies FAILED" -ForegroundColor Red
  exit 1
}
Write-Host "==> smoke-policies PASSED" -ForegroundColor Green
exit 0
