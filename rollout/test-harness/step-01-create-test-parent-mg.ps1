<#
.SYNOPSIS
    Step 01 — create a synthetic intermediate Platform MG under Tenant Root
    so the rollout has somewhere to anchor (mimics a typical enterprise environment
    where a Platform MG already exists).

.DESCRIPTION
    In an enterprise tenant, an org-level Platform MG already exists. In a clean
    MCAPS dev tenant, only Tenant Root Group exists. This script creates
    'mg-klz-test-platform' under root so pilot-test.psd1 has a valid
    ParentManagementGroupId target.

    Safe to run multiple times.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'

$mg = 'mg-klz-test-platform'

$existing = az account management-group show --name $mg --output json 2>$null
if ($existing) {
    Write-Host "MG '$mg' already exists. No-op." -ForegroundColor Yellow
    return
}

if (-not $PSCmdlet.ShouldProcess($mg, "Create MG under Tenant Root")) {
    Write-Host "[WhatIf] Would create '$mg' under Tenant Root" -ForegroundColor Cyan
    return
}

az account management-group create --name $mg --display-name 'KLZ Test Platform' | Out-Null
Write-Host "Created MG '$mg' under Tenant Root." -ForegroundColor Green
Write-Host ""
Write-Host "Verify:" -ForegroundColor Cyan
Write-Host "  az account management-group show --name $mg --query 'details.parent.id' -o tsv"
