<#
.SYNOPSIS
    Wraps policy/assign-mg-initiative.ps1 with values from customer.psd1 and
    drives it past its built-in -DryRun:$true default.

.PARAMETER ConfigPath
    Path to customer.psd1.

.PARAMETER WhatIf
    Run the inner script in DryRun mode (no changes).

.EXAMPLE
    # Preview only
    .\20-mg-policy-assign.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf

    # Actually publish + assign at the effect specified in customer.psd1
    .\20-mg-policy-assign.ps1 -ConfigPath ..\config\customer.psd1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$inner    = Join-Path $repoRoot 'policy\assign-mg-initiative.ps1'
if (-not (Test-Path $inner)) { throw "Inner script not found: $inner" }

# Az PowerShell and Az CLI maintain SEPARATE token caches. The inner script uses
# New-AzPolicy* cmdlets (Az.Resources), so the Az PowerShell session must be
# signed into the SAME tenant + subscription the rest of the rollout targets.
# This is the most common failure mode when a user has multiple tenants (e.g.
# corp @microsoft.com vs MCAPS dev) configured in different tools.
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    throw "Az.Accounts module not installed. Run: Install-Module Az -Scope CurrentUser -Force"
}
Import-Module Az.Accounts -ErrorAction Stop
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Tenant.Id -ne $cfg.TenantId -or $ctx.Subscription.Id -ne $cfg.SubscriptionId) {
    Write-Host "==> Az PowerShell context is wrong (tenant=$($ctx.Tenant.Id) sub=$($ctx.Subscription.Id))" -ForegroundColor Yellow
    Write-Host "    Expected: tenant=$($cfg.TenantId) sub=$($cfg.SubscriptionId)" -ForegroundColor Yellow
    Write-Host "    Signing in via Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount -Tenant $cfg.TenantId -Subscription $cfg.SubscriptionId -WarningAction SilentlyContinue | Out-Null
    $ctx = Get-AzContext
}
Write-Host "==> Az PowerShell context: user=$($ctx.Account.Id) tenant=$($ctx.Tenant.Id) sub=$($ctx.Subscription.Id)" -ForegroundColor Cyan

$dryRun = $WhatIfPreference -or -not $PSCmdlet.ShouldProcess($cfg.AiLandingZoneManagementGroupId, "Assign initiative at effect=$($cfg.PolicyEffect)")

if ($cfg.PolicyEffect -eq 'Deny' -and -not $dryRun) {
    Write-Host ""
    Write-Host "  !! POLICY EFFECT = Deny  !!  This will BLOCK non-compliant resource creation tenant-wide on this MG." -ForegroundColor Red
    Write-Host "     Recommend: run with Audit first for >= 1 week, prove zero violations, then switch to Deny." -ForegroundColor Red
    $resp = Read-Host "Type the literal word DENY to proceed (any other input cancels)"
    if ($resp -ne 'DENY') { Write-Host "Cancelled."; return }
}

& $inner `
    -ManagementGroupId       $cfg.AiLandingZoneManagementGroupId `
    -SubscriptionId          $cfg.SubscriptionId `
    -LogAnalyticsWorkspaceId $cfg.LogAnalyticsWorkspaceId `
    -Mode                    $cfg.PolicyEffect `
    -DryRun:$dryRun
