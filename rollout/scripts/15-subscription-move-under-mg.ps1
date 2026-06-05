<#
.SYNOPSIS
    Moves the configured Foundry resource groups under the AI Landing Zone MG
    so the policy initiative actually evaluates them.

.DESCRIPTION
    This is REVERSIBLE: 99-rollback-all.ps1 moves them back to the parent MG.

    Subscriptions and resource groups follow MG inheritance. To move a
    resource group's MG context, you actually move its parent subscription —
    Azure does not allow moving a single RG across MG boundaries. So this
    script:
      * Reads the subscription that owns each listed RG.
      * Moves those subscriptions under the AI Landing Zone MG.
      * Logs a warning per unique subscription so the operator knows
        scope is widening.

.PARAMETER ConfigPath
    Path to customer.psd1.

.PARAMETER WhatIf
    Print planned moves without executing.

.EXAMPLE
    .\15-subscription-move-under-mg.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
if (-not $cfg.ResourceGroupsToMove -or $cfg.ResourceGroupsToMove.Count -eq 0) {
    Write-Host "No RGs listed in cfg.ResourceGroupsToMove. Nothing to do." -ForegroundColor Yellow
    return
}

# Build the set of unique subscriptions that own the listed RGs.
$subsToMove = @{}
foreach ($rg in $cfg.ResourceGroupsToMove) {
    $rgInfo = az group show --name $rg --output json 2>$null | ConvertFrom-Json
    if (-not $rgInfo) {
        Write-Warning "RG '$rg' not visible to current sub-context. Skipping."
        continue
    }
    # rgInfo.id starts with /subscriptions/<guid>/...
    $subId = ($rgInfo.id -split '/')[2]
    $subsToMove[$subId] = $true
}

if ($subsToMove.Count -eq 0) {
    Write-Host "No subscriptions resolved from configured RG list. Nothing to do." -ForegroundColor Yellow
    return
}

Write-Host "==> Subscriptions to move under MG '$($cfg.AiLandingZoneManagementGroupId)':" -ForegroundColor Cyan
foreach ($s in $subsToMove.Keys) { Write-Host "       $s" -ForegroundColor Cyan }
Write-Host "    NOTE: every RG in each subscription will inherit the AI Landing Zone MG's policies." -ForegroundColor Yellow

foreach ($subId in $subsToMove.Keys) {
    if (-not $PSCmdlet.ShouldProcess($subId, "Move subscription under MG '$($cfg.AiLandingZoneManagementGroupId)'")) {
        Write-Host "    [WhatIf] az account management-group subscription add --name $($cfg.AiLandingZoneManagementGroupId) --subscription $subId" -ForegroundColor Cyan
        continue
    }
    az account management-group subscription add `
        --name $cfg.AiLandingZoneManagementGroupId `
        --subscription $subId | Out-Null
    Write-Host "    Moved $subId" -ForegroundColor Green
}
