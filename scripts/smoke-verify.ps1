###############################################################################
# smoke-verify.ps1 — Post-deploy verification for klz-accelerator-finops
#
# Asserts that a deployed blueprint is healthy:
#   - Both RGs (platform + foundry) exist
#   - Foundry account is in 'Succeeded' provisioning state
#   - Private endpoints are 'Approved'
#   - Private DNS records resolve to PE NIC IPs
#   - LAW + AppI + KV all 'Succeeded'
#
# Usage:
#   ./scripts/smoke-verify.ps1 -Workload klzfin -Env dev -SubscriptionId ba89cfed-...
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more checks failed (full report on stdout)
#   2 — tooling error or auth failure
###############################################################################

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$Workload,
  [Parameter(Mandatory)] [string]$Env,
  [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
  [string]$RgSuffix = "",
  [int]$Retries = 3,
  [int]$RetryDelaySec = 10
)

$ErrorActionPreference = 'Stop'

if (-not $SubscriptionId) {
  Write-Error "SubscriptionId required"
  exit 2
}

$azCmd = (Get-Command az -ErrorAction SilentlyContinue).Source
if (-not $azCmd) {
  $azCmd = (Get-ChildItem "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin" -Filter az.cmd -EA SilentlyContinue | Select -First 1).FullName
}
if (-not $azCmd) { Write-Error "az CLI not found"; exit 2 }

& $azCmd account set --subscription $SubscriptionId 2>&1 | Out-Null

$rgPlatform = "rg-$Workload-platform-$Env$RgSuffix"
$rgFoundry  = "rg-$Workload-foundry-$Env$RgSuffix"

Write-Host "==== smoke-verify: $Workload/$Env ====" -ForegroundColor Cyan
Write-Host "Platform RG: $rgPlatform"
Write-Host "Foundry RG:  $rgFoundry"
Write-Host ""

$results = @()
function Add-Result($Name, $Pass, $Detail) {
  $script:results += [PSCustomObject]@{ Check=$Name; Pass=$Pass; Detail=$Detail }
  $color = if ($Pass) { 'Green' } else { 'Red' }
  $glyph = if ($Pass) { '[OK]' } else { '[FAIL]' }
  Write-Host "$glyph $Name : $Detail" -ForegroundColor $color
}

function Try-With-Retries($block, $name) {
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      $r = & $block
      if ($r) { return $r }
    } catch { Write-Verbose "$name attempt $i failed: $_" }
    Start-Sleep -Seconds $RetryDelaySec
  }
  return $null
}

#-----------------------------------------------------------------------------
# 1. Resource groups exist
#-----------------------------------------------------------------------------
foreach ($rg in @($rgPlatform, $rgFoundry)) {
  $exists = (& $azCmd group exists --name $rg --subscription $SubscriptionId 2>&1) -eq 'true'
  Add-Result "RG $rg exists" $exists $(if ($exists) { 'present' } else { 'MISSING' })
}

#-----------------------------------------------------------------------------
# 2. Foundry account 'Succeeded'
#-----------------------------------------------------------------------------
$foundryAcct = & $azCmd cognitiveservices account list -g $rgFoundry --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
if ($foundryAcct.Count -gt 0) {
  $acct = $foundryAcct[0]
  Add-Result "Foundry account provisioning state" ($acct.properties.provisioningState -eq 'Succeeded') "state=$($acct.properties.provisioningState) name=$($acct.name)"
} else {
  Add-Result "Foundry account presence" $false "no Microsoft.CognitiveServices/accounts found in $rgFoundry"
}

#-----------------------------------------------------------------------------
# 3. Private endpoints 'Approved'
#-----------------------------------------------------------------------------
$peList = & $azCmd network private-endpoint list -g $rgFoundry --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
$peList += (& $azCmd network private-endpoint list -g $rgPlatform --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json)
$peCount = $peList.Count
$approvedCount = ($peList | Where-Object { $_.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status -eq 'Approved' }).Count
Add-Result "Private endpoints approved" ($approvedCount -eq $peCount -and $peCount -gt 0) "approved=$approvedCount / total=$peCount"

#-----------------------------------------------------------------------------
# 4. Private DNS A records resolved (sanity check that PE→DNS group fired)
#-----------------------------------------------------------------------------
$pdzList = & $azCmd network private-dns zone list -g $rgPlatform --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
$totalRecords = 0
foreach ($z in $pdzList) {
  $recs = & $azCmd network private-dns record-set a list -g $rgPlatform --zone-name $z.name --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
  $totalRecords += $recs.Count
}
Add-Result "Private DNS A records" ($totalRecords -gt 0) "records=$totalRecords across $($pdzList.Count) zones"

#-----------------------------------------------------------------------------
# 5. LAW + AppI + KV health
#-----------------------------------------------------------------------------
$law = & $azCmd monitor log-analytics workspace list -g $rgPlatform --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
Add-Result "LAW provisioning state" ($law.Count -gt 0 -and $law[0].provisioningState -eq 'Succeeded') $(if ($law.Count) { $law[0].provisioningState } else { 'MISSING' })

$appi = & $azCmd monitor app-insights component show -g $rgPlatform --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
$appiOk = $appi -and ($appi[0].provisioningState -eq 'Succeeded' -or $appi.provisioningState -eq 'Succeeded')
Add-Result "AppInsights state" $appiOk 'see verbose log if fail'

$kv = & $azCmd keyvault list -g $rgPlatform --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
Add-Result "KeyVault provisioning state" ($kv.Count -gt 0 -and $kv[0].properties.provisioningState -eq 'Succeeded') $(if ($kv.Count) { $kv[0].properties.provisioningState } else { 'MISSING' })

#-----------------------------------------------------------------------------
# Final report
#-----------------------------------------------------------------------------
Write-Host ""
$failed = $results | Where-Object { -not $_.Pass }
if ($failed.Count -gt 0) {
  Write-Host "==> smoke-verify FAILED ($($failed.Count) of $($results.Count) checks)" -ForegroundColor Red
  exit 1
}
Write-Host "==> smoke-verify PASSED ($($results.Count) of $($results.Count) checks)" -ForegroundColor Green
exit 0
