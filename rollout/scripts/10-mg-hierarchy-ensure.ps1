<#
.SYNOPSIS
    Idempotently ensures the AI Landing Zone management group exists under
    the configured parent MG.

.DESCRIPTION
    Wraps policy/mg/main.bicep deployment. If the target MG already exists
    AND has the correct parent, this is a no-op. Otherwise it creates it.

.PARAMETER ConfigPath
    Path to customer.psd1.

.PARAMETER WhatIf
    Print the planned deployment without making changes.

.EXAMPLE
    .\10-mg-hierarchy-ensure.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
    .\10-mg-hierarchy-ensure.ps1 -ConfigPath ..\config\customer.psd1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$bicep    = Join-Path $repoRoot 'policy\mg\main.bicep'
if (-not (Test-Path $bicep)) { throw "Template not found: $bicep" }

Write-Host "==> Ensuring MG '$($cfg.AiLandingZoneManagementGroupId)' under parent '$($cfg.ParentManagementGroupId)'..."

$existing = az account management-group show --name $cfg.AiLandingZoneManagementGroupId --output json 2>$null | ConvertFrom-Json
if ($existing) {
    # az CLI returns a flat shape: details.parent.{id,name} (no 'properties' wrapper).
    $parentName = if ($existing.details.parent.name) { $existing.details.parent.name } else { ($existing.details.parent.id -split '/')[-1] }
    if ($parentName -eq $cfg.ParentManagementGroupId) {
        Write-Host "    Already exists with correct parent. Skipping." -ForegroundColor Yellow
        return
    } else {
        throw "MG '$($cfg.AiLandingZoneManagementGroupId)' exists but parent is '$parentName' (expected '$($cfg.ParentManagementGroupId)'). Resolve manually before continuing."
    }
}

$deployName = "klz-mg-ailz-$(Get-Date -Format yyyyMMddHHmm)"
# Deploy at the PARENT MG scope (where the caller already has rights).
# Tenant-scope deployments require Owner at Tenant Root which is rarely granted.
$args = @(
    'deployment','mg','create',
    '--management-group-id', $cfg.ParentManagementGroupId,
    '--name', $deployName,
    '--location', $cfg.Location,
    '--template-file', $bicep,
    '--parameters',
        "parentManagementGroupId=$($cfg.ParentManagementGroupId)",
        "aiLandingZoneManagementGroupId=$($cfg.AiLandingZoneManagementGroupId)",
        "aiLandingZoneDisplayName=$($cfg.AiLandingZoneDisplayName)"
)

if ($WhatIfPreference -or -not $PSCmdlet.ShouldProcess($cfg.ParentManagementGroupId, "Create MG '$($cfg.AiLandingZoneManagementGroupId)' under '$($cfg.ParentManagementGroupId)'")) {
    Write-Host "    [WhatIf] az $($args -join ' ')" -ForegroundColor Cyan
    return
}

$rawOut = & az @args 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ($rawOut | Out-String) -ForegroundColor Red
    throw "MG deployment FAILED (exit $LASTEXITCODE). See error above."
}
Write-Host "    Done." -ForegroundColor Green
