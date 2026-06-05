<#
.SYNOPSIS
    Snapshots the compliance state of the KLZ Foundry Enterprise Baseline
    initiative and writes a CSV summary + per-policy CSV breakdown.

.DESCRIPTION
    Queries Microsoft.PolicyInsights/policyStates for an assignment, then
    rolls up counts by policyDefinitionReferenceId. Output goes to:
      ./out/policy-compliance-summary-<timestamp>.csv
      ./out/policy-compliance-detail-<timestamp>.csv

.PARAMETER ManagementGroupId
    Scope at which the policy is assigned.

.PARAMETER AssignmentName
    Defaults to 'klz-foundry-baseline-assignment' (matches assign-mg-initiative.ps1).

.PARAMETER OutputDir
    Where to drop the CSVs. Defaults to ./out under the repo root.

.EXAMPLE
    .\policy-compliance-report.ps1 -ManagementGroupId klz-root
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ManagementGroupId,
    [string] $AssignmentName = 'klz-foundry-baseline-assignment',
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'

# --- Resolve paths ----------------------------------------------------------
$repoRoot = Resolve-Path -Path (Join-Path $PSScriptRoot '..')
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'out' }
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$timestamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$summaryFile   = Join-Path $OutputDir "policy-compliance-summary-$timestamp.csv"
$detailFile    = Join-Path $OutputDir "policy-compliance-detail-$timestamp.csv"
$mgScope       = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
$assignmentId  = "$mgScope/providers/Microsoft.Authorization/policyAssignments/$AssignmentName"

Write-Host "Querying Microsoft.PolicyInsights for $assignmentId ..." -ForegroundColor Cyan

# --- Latest state per resource for this assignment -------------------------
$states = Get-AzPolicyState `
    -ManagementGroupName $ManagementGroupId `
    -Filter "PolicyAssignmentId eq '$assignmentId'" `
    -Top 5000

if (-not $states -or $states.Count -eq 0) {
    Write-Warning "No policy states found. Either the assignment is too new (<30 min) or the scope is wrong."
    return
}

# --- Per-policy summary ----------------------------------------------------
$summary = $states |
    Group-Object PolicyDefinitionReferenceId |
    ForEach-Object {
        $compliant     = ($_.Group | Where-Object ComplianceState -eq 'Compliant').Count
        $nonCompliant  = ($_.Group | Where-Object ComplianceState -eq 'NonCompliant').Count
        $exempt        = ($_.Group | Where-Object ComplianceState -eq 'Exempt').Count
        $total         = $_.Group.Count
        $pctCompliant  = if ($total -gt 0) { [Math]::Round(($compliant / $total) * 100, 1) } else { 0 }

        [PSCustomObject]@{
            PolicyDefinitionReferenceId = $_.Name
            TotalResources              = $total
            Compliant                   = $compliant
            NonCompliant                = $nonCompliant
            Exempt                      = $exempt
            PercentCompliant            = $pctCompliant
        }
    } |
    Sort-Object PercentCompliant

$summary | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8

# --- Per-resource detail (only non-compliant) -----------------------------
$detail = $states |
    Where-Object ComplianceState -eq 'NonCompliant' |
    Select-Object `
        @{N='PolicyRef';        E={$_.PolicyDefinitionReferenceId}},
        @{N='ResourceId';       E={$_.ResourceId}},
        @{N='ResourceType';     E={$_.ResourceType}},
        @{N='ResourceLocation'; E={$_.ResourceLocation}},
        @{N='SubscriptionId';   E={$_.SubscriptionId}},
        @{N='ComplianceState';  E={$_.ComplianceState}},
        @{N='Timestamp';        E={$_.Timestamp}}

$detail | Export-Csv -Path $detailFile -NoTypeInformation -Encoding UTF8

# --- Print top offenders ---------------------------------------------------
Write-Host ""
Write-Host "Summary written to : $summaryFile" -ForegroundColor Green
Write-Host "Detail  written to : $detailFile"  -ForegroundColor Green
Write-Host ""
Write-Host "Top 5 lowest-compliance policies:" -ForegroundColor Yellow
$summary | Select-Object -First 5 | Format-Table -AutoSize
