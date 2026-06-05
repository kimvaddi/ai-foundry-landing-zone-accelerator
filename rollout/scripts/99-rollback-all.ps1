<#
.SYNOPSIS
    Reverses the rollout: removes policy assignment, custom defs, AI Landing
    Zone MG, and (optionally) re-parents moved subscriptions back to the
    original parent.

.PARAMETER ConfigPath
    Path to customer.psd1.

.PARAMETER KeepMG
    If set, leaves the AI Landing Zone MG in place (just removes policies).

.PARAMETER WhatIf
    Print planned removals without executing.

.EXAMPLE
    .\99-rollback-all.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [switch] $KeepMG
)
$ErrorActionPreference = 'Continue'   # rollback should keep going if one step fails

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$mg  = $cfg.AiLandingZoneManagementGroupId
$mgScope = "/providers/Microsoft.Management/managementGroups/$mg"

function _Step($label, $sb) {
    Write-Host ""
    Write-Host "==> $label" -ForegroundColor Cyan
    if (-not $PSCmdlet.ShouldProcess($mg, $label)) {
        Write-Host "    [WhatIf]" -ForegroundColor Yellow
        return
    }
    try { & $sb } catch { Write-Warning "Step failed: $($_.Exception.Message)" }
}

# 1. Remove policy assignments scoped to this MG
# NOTE: Inline JMESPath `?` filters get mangled by cmd.exe when az.cmd is invoked
# from pwsh on Windows ('].name was unexpected at this time.'). Filter in PS instead.
_Step "Remove policy assignments at MG '$mg'" {
    $names = az policy assignment list --scope $mgScope --query "[].name" -o tsv | Where-Object { $_ -like 'klz-*' }
    foreach ($n in $names) {
        Write-Host "    removing assignment $n"
        az policy assignment delete --name $n --scope $mgScope 2>&1 | Out-Null
    }
}

# 2. Remove custom initiative
_Step "Remove custom initiative at MG '$mg'" {
    $sets = az policy set-definition list --management-group $mg --query "[].name" -o tsv | Where-Object { $_ -like 'klz-*' }
    foreach ($s in $sets) {
        Write-Host "    removing initiative $s"
        az policy set-definition delete --name $s --management-group $mg 2>&1 | Out-Null
    }
}

# 3. Remove custom policy definitions
_Step "Remove custom policy definitions at MG '$mg'" {
    $defs = az policy definition list --management-group $mg --query "[].name" -o tsv | Where-Object { $_ -like 'klz-*' }
    foreach ($d in $defs) {
        Write-Host "    removing definition $d"
        az policy definition delete --name $d --management-group $mg 2>&1 | Out-Null
    }
}

# 4. Optionally move subscriptions back to the parent MG
if ($cfg.ResourceGroupsToMove -and $cfg.ResourceGroupsToMove.Count -gt 0) {
    _Step "Move subscriptions back to parent MG '$($cfg.ParentManagementGroupId)'" {
        $subsToMove = @{}
        foreach ($rg in $cfg.ResourceGroupsToMove) {
            $rgInfo = az group show --name $rg --output json 2>$null | ConvertFrom-Json
            if ($rgInfo) { $subsToMove[($rgInfo.id -split '/')[2]] = $true }
        }
        foreach ($subId in $subsToMove.Keys) {
            Write-Host "    moving $subId back to $($cfg.ParentManagementGroupId)"
            az account management-group subscription add --name $cfg.ParentManagementGroupId --subscription $subId 2>&1 | Out-Null
        }
    }
}

# 5. Delete the MG itself (unless -KeepMG)
if (-not $KeepMG) {
    _Step "Delete AI Landing Zone MG '$mg'" {
        az account management-group delete --name $mg 2>&1 | Out-Null
    }
}

Write-Host ""
Write-Host "Rollback complete (or printed in WhatIf mode)." -ForegroundColor Green
