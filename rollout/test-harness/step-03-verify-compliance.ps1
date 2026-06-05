<#
.SYNOPSIS
    Step 03 — exports policy compliance state at the test MG to proof/.

.DESCRIPTION
    Run >=30 minutes after step-02 so Azure Policy has time to evaluate.
    Captures:
        - Initiative assignment compliance summary (per-policy pass/fail)
        - All non-compliant resources (resource id + policy that failed)
        - Foundry account resource details (for context)

.PARAMETER ConfigPath
    Defaults to ../config/pilot-test.psd1.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1')
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$mg  = $cfg.AiLandingZoneManagementGroupId
$mgScope = "/providers/Microsoft.Management/managementGroups/$mg"

$proof = Join-Path $PSScriptRoot 'proof\step-03'
New-Item -ItemType Directory -Force -Path $proof | Out-Null
$ts = Get-Date -Format yyyyMMdd-HHmmss

Write-Host "==> Collecting compliance state at $mgScope ..." -ForegroundColor Cyan

# Trigger fresh evaluation (best-effort; may take a few minutes to actually run)
# NOTE: --no-wait is REQUIRED. Without it `az policy state trigger-scan` blocks
# 5-20 minutes per RG synchronously, which makes this whole step hang. With it,
# the scan kicks off async and we read whatever evaluation Azure already has.
Write-Host "    Triggering policy scan (async, no-wait)..."
az policy state trigger-scan --resource-group rg-klzfin-foundry-dev --no-wait 2>$null | Out-Null
az policy state trigger-scan --resource-group rg-klzfin-platform-dev --no-wait 2>$null | Out-Null

# Compliance summary
$summary = Join-Path $proof "compliance-summary-$ts.json"
az policy state summarize --management-group $mg --output json | Out-File -FilePath $summary -Encoding utf8
Write-Host "    Wrote $summary"

# Non-compliant resources
$nc = Join-Path $proof "non-compliant-$ts.json"
az policy state list --management-group $mg --filter "complianceState eq 'NonCompliant'" --output json | Out-File -FilePath $nc -Encoding utf8
Write-Host "    Wrote $nc"

# Foundry-specific
$fdry = az cognitiveservices account list --resource-group rg-klzfin-foundry-dev --query "[0]" -o json | ConvertFrom-Json
if ($fdry) {
    $fdryFile = Join-Path $proof "foundry-account-$ts.json"
    $fdry | ConvertTo-Json -Depth 10 | Out-File -FilePath $fdryFile -Encoding utf8
    Write-Host "    Wrote $fdryFile"

    $fdryPolicy = Join-Path $proof "foundry-policy-state-$ts.json"
    az policy state list --resource $fdry.id --output json | Out-File -FilePath $fdryPolicy -Encoding utf8
    Write-Host "    Wrote $fdryPolicy"
}

Write-Host ""
Write-Host "Done. Inspect with:" -ForegroundColor Green
Write-Host "  Get-Content $summary | ConvertFrom-Json | Select-Object -ExpandProperty value"
Write-Host "  Get-Content $nc      | ConvertFrom-Json | Select-Object -ExpandProperty value | Format-Table"
