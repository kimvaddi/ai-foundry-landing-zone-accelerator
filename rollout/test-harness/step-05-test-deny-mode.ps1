<#
.SYNOPSIS
    Step 05 — proves Deny mode actually blocks. Creates a TEMPORARY assignment
    scoped to a single resource group (NOT the MG) at effect=Deny, then tries
    to deploy a non-allowlisted model deployment. Asserts 403, then deletes
    the assignment.

.DESCRIPTION
    The MG-scoped initiative stays at Audit throughout. This script only
    validates the Deny code path without touching the broader policy state.

    Important: requires the live Foundry account from the smoke deploy.
    Tries to add a model deployment named 'gpt-3.5-turbo' which is NOT in
    the allowlist (gpt-4o / gpt-4o-mini / o3-mini / text-embedding-3-*).

.PARAMETER ConfigPath
    Defaults to ../config/pilot-test.psd1.
.PARAMETER WaitSeconds
    Seconds to wait between assignment create and deploy attempt. Default 600
    (10 min) — Azure Policy Deny enforcement typically takes 5-15 min to
    propagate after a fresh assignment. 60s is too short and gives false negatives.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1'),
    [int]    $WaitSeconds = 600
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$proof = Join-Path $PSScriptRoot 'proof\step-05'
New-Item -ItemType Directory -Force -Path $proof | Out-Null
$ts = Get-Date -Format yyyyMMdd-HHmmss

$rg     = 'rg-klzfin-foundry-dev'
$rgScope = "/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$rg"
$asgName = "klz-test-deny-models-$($ts -replace '-','')"

$fdry = az cognitiveservices account list --resource-group $rg --query "[0]" -o json | ConvertFrom-Json
if (-not $fdry) { throw "Foundry account not found in $rg. Run smoke deploy first." }
Write-Host "==> Foundry account: $($fdry.name)" -ForegroundColor Cyan

# 1. Verify the custom policy def exists at MG (it should, from step 02).
$defId = az policy definition show --name 'klz-cognitive-model-allowlist' --management-group $cfg.AiLandingZoneManagementGroupId --query id -o tsv 2>$null
if (-not $defId) { throw "Custom policy def 'klz-cognitive-model-allowlist' not found at MG. Run step-02 first." }
Write-Host "    Def id: $defId"

# 2. Create RG-scoped Deny assignment (overrides MG-scoped Audit on this RG only)
Write-Host "==> Creating TEMPORARY Deny assignment on $rgScope..." -ForegroundColor Cyan
$params = @{
    allowedModels = @{ value = @('gpt-4o','gpt-4o-mini','o3-mini','text-embedding-3-large','text-embedding-3-small') }
    effect        = @{ value = 'Deny' }
} | ConvertTo-Json -Depth 5 -Compress

$pf = New-TemporaryFile
Set-Content -Path $pf -Value $params -Encoding utf8

az policy assignment create `
    --name $asgName `
    --display-name 'KLZ test — Deny non-allowlist models (temporary)' `
    --scope $rgScope `
    --policy $defId `
    --params $pf | Out-Null
Remove-Item $pf -Force

Write-Host "    Created assignment $asgName"

# Verify effect actually bound (silent param-binding failure is a known pitfall)
$asg = az policy assignment show --name $asgName --scope $rgScope --output json | ConvertFrom-Json
$boundEffect = $asg.parameters.effect.value
Write-Host "    Verified bound effect: $boundEffect"
if ($boundEffect -ne 'Deny') {
    throw "Assignment was created but effect=$boundEffect, not Deny. Aborting test."
}

Write-Host "    Waiting ${WaitSeconds}s for policy to be active (Deny enforcement typically needs 5-15 min)..."
Start-Sleep -Seconds $WaitSeconds

# 3. Try to add a non-allowlisted model — expect 403 RequestDisallowedByPolicy.
#    Must pick a model that is currently GA in Azure OpenAI (not deprecated)
#    AND not present in the allowlist. gpt-4.1 (2025-04-14) fits as of 2026-05.
Write-Host "==> Attempting to deploy disallowed model (expect 403)..." -ForegroundColor Cyan
$attemptName = "test-deny-gpt41-$ts"
try {
    $out = az cognitiveservices account deployment create `
        --resource-group $rg `
        --name $fdry.name `
        --deployment-name $attemptName `
        --model-name 'gpt-4.1' `
        --model-version '2025-04-14' `
        --model-format 'OpenAI' `
        --sku-name 'Standard' `
        --sku-capacity 1 2>&1
    $exit = $LASTEXITCODE
} catch {
    $out  = $_.Exception.Message
    $exit = 1
}

$proofFile = Join-Path $proof "deny-attempt-$ts.json"
@{
    attempted = $attemptName
    exitCode  = $exit
    output    = ($out | Out-String)
    expected  = '403 RequestDisallowedByPolicy'
} | ConvertTo-Json -Depth 5 | Out-File $proofFile -Encoding utf8

if ($exit -eq 0) {
    Write-Warning "Deployment SUCCEEDED. Policy did NOT block. Investigate."
    Write-Host "    Cleaning up created deployment..." -ForegroundColor Yellow
    az cognitiveservices account deployment delete --resource-group $rg --name $fdry.name --deployment-name $attemptName 2>&1 | Out-Null
} else {
    if (($out | Out-String) -match 'RequestDisallowedByPolicy|disallowedByPolicy|PolicyViolation|Forbidden') {
        Write-Host "    PASS — policy denied the request." -ForegroundColor Green
    } else {
        Write-Warning "Failed but not with the expected policy error. Inspect $proofFile"
    }
}

# 4. Clean up the temporary assignment
Write-Host "==> Removing temporary Deny assignment..." -ForegroundColor Cyan
az policy assignment delete --name $asgName --scope $rgScope 2>&1 | Out-Null
Write-Host "    Done."

Write-Host ""
Write-Host "Proof written to $proofFile" -ForegroundColor Green
