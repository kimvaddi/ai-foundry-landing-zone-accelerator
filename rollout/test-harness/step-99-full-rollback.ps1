<#
.SYNOPSIS
    Step 99 — full rollback of everything step-01..05 created.

.DESCRIPTION
    Order matters:
        1. Run ../scripts/99-rollback-all.ps1 (removes assignments, defs, ailz MG, moves sub back)
        2. Delete the synthetic mg-klz-test-platform itself

.PARAMETER ConfigPath
    Defaults to ../config/pilot-test.psd1.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1')
)
$ErrorActionPreference = 'Continue'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$scripts = Join-Path $PSScriptRoot '..\scripts'

Write-Host "==> Running rollout rollback (../scripts/99-rollback-all.ps1)..." -ForegroundColor Cyan
& (Join-Path $scripts '99-rollback-all.ps1') -ConfigPath $ConfigPath -Confirm:$false

Write-Host ""
Write-Host "==> Removing synthetic mg-klz-test-platform..." -ForegroundColor Cyan
$mgRoot = 'mg-klz-test-platform'
$exists = az account management-group show --name $mgRoot --output json 2>$null
if (-not $exists) {
    Write-Host "    Already gone." -ForegroundColor Yellow
} else {
    if ($PSCmdlet.ShouldProcess($mgRoot, "Delete synthetic test parent MG")) {
        az account management-group delete --name $mgRoot 2>&1 | Out-Null
        Write-Host "    Deleted." -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Final state — running 'az account management-group list':" -ForegroundColor Cyan
az account management-group list --query "[].{name:name,displayName:displayName}" -o table
