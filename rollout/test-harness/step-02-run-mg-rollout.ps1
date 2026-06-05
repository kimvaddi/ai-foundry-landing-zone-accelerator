<#
.SYNOPSIS
    Step 02 — runs the full MG-policy rollout (00 -> 10 -> 15 -> 20) against
    the maintainer's synthetic test parent MG. Effect stays at Audit; nothing in the maintainer's
    tenant is blocked.

.PARAMETER ConfigPath
    Defaults to ../config/pilot-test.psd1.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1')
)
$ErrorActionPreference = 'Stop'

$scripts = Join-Path $PSScriptRoot '..\scripts'
$proof   = Join-Path $PSScriptRoot 'proof\step-02'
New-Item -ItemType Directory -Force -Path $proof | Out-Null
$ts = Get-Date -Format yyyyMMdd-HHmmss
$log = Join-Path $proof "rollout-$ts.log"

Write-Host "==> Running MG rollout. Tee output to $log" -ForegroundColor Cyan

& {
    Write-Host "--- 00-preflight ---"
    & (Join-Path $scripts '00-preflight.ps1') -ConfigPath $ConfigPath

    Write-Host ""
    Write-Host "--- 10-mg-hierarchy-ensure ---"
    & (Join-Path $scripts '10-mg-hierarchy-ensure.ps1') -ConfigPath $ConfigPath

    Write-Host ""
    Write-Host "--- 15-subscription-move-under-mg ---"
    Write-Host "*** CAUTION: this moves your Azure subscription under the AI Landing Zone test MG." -ForegroundColor Yellow
    Write-Host "*** Every RG in the sub will inherit the test MG's policy assignments (Audit only)." -ForegroundColor Yellow
    $resp = Read-Host "Continue? (yes/no)"
    if ($resp -ne 'yes') { Write-Warning "Skipped step 15. Step 20 will publish defs but compliance will be empty."; }
    else { & (Join-Path $scripts '15-subscription-move-under-mg.ps1') -ConfigPath $ConfigPath }

    Write-Host ""
    Write-Host "--- 20-mg-policy-assign ---"
    & (Join-Path $scripts '20-mg-policy-assign.ps1') -ConfigPath $ConfigPath
} *>&1 | Tee-Object -FilePath $log

Write-Host ""
Write-Host "Done. Compliance evaluation takes ~30 min. Run step-03 after waiting." -ForegroundColor Green
Write-Host "Log: $log"
