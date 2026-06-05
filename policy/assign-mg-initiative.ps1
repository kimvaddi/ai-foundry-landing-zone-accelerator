<#
.SYNOPSIS
    Publishes KLZ custom policy definitions + the Foundry Enterprise Baseline
    initiative to a management group, then optionally creates an assignment.

.DESCRIPTION
    Phase B safety: this script DEFAULTS TO DRYRUN. It will:
      * Always print what it WOULD do.
      * Only execute when -DryRun:$false is explicitly passed.
      * Default assignment Mode is "Audit" (no enforcement).
      * Setting -Mode Deny is allowed but requires -Confirm acknowledgement
        because it changes tenant-wide guardrails.

    Use this script ONLY after CISO / cybersec sign-off on the policy set.

.PARAMETER ManagementGroupId
    Target MG ID (without /providers/... prefix). Required.

.PARAMETER SubscriptionId
    Subscription where the KLZ workload runs (used to build the policyDefinition
    self-references and for the Log Analytics workspace lookup). Required.

.PARAMETER LogAnalyticsWorkspaceId
    Resource ID of the LAW that DeployIfNotExists diagnostic settings target.

.PARAMETER Mode
    Effect to use for the initiative's parameterised 'effect' input.
    Defaults to Audit. Allowed: Audit, Deny, Disabled.

.PARAMETER DryRun
    When true (default) prints planned actions, makes no changes.

.EXAMPLE
    # Preview only — recommended first run.
    .\assign-mg-initiative.ps1 -ManagementGroupId klz-root `
        -SubscriptionId 22222222-2222-2222-2222-222222222222 `
        -LogAnalyticsWorkspaceId /subscriptions/.../workspaces/log-klzfin-dev-c6ej

.EXAMPLE
    # Actually publish in Audit mode (still no Deny).
    .\assign-mg-initiative.ps1 -ManagementGroupId klz-root `
        -SubscriptionId 22222222-2222-2222-2222-222222222222 `
        -LogAnalyticsWorkspaceId /subscriptions/.../workspaces/log-klzfin-dev-c6ej `
        -DryRun:$false

.NOTES
    Requires Az.Resources >= 6.0.0. Run as a user with at least
    'Resource Policy Contributor' at the target MG scope.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)] [string] $ManagementGroupId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $LogAnalyticsWorkspaceId,
    [ValidateSet('Audit','Deny','Disabled')] [string] $Mode = 'Audit',
    [bool] $DryRun = $true
)

$ErrorActionPreference = 'Stop'

# --- Resolve repo-root-relative paths so the script works from anywhere ----
$repoRoot   = Resolve-Path -Path (Join-Path $PSScriptRoot '..')
$defDir     = Join-Path $repoRoot 'policy\definitions'
$initFile   = Join-Path $repoRoot 'policy\initiative\foundry-enterprise-baseline.json'
$mgScope    = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"

if (-not (Test-Path $defDir))    { throw "Definitions folder not found: $defDir" }
if (-not (Test-Path $initFile))  { throw "Initiative file not found: $initFile" }

Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " KLZ Foundry Enterprise Baseline — MG assignment helper" -ForegroundColor Cyan
Write-Host "   Management Group : $ManagementGroupId" -ForegroundColor Cyan
Write-Host "   Effect Mode      : $Mode" -ForegroundColor Cyan
Write-Host "   DryRun           : $DryRun" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan

if ($Mode -eq 'Deny' -and -not $DryRun) {
    if (-not $PSCmdlet.ShouldProcess($mgScope, "Deploy Foundry Enterprise Baseline with effect=Deny")) {
        Write-Warning 'User declined Deny mode confirmation; aborting.'
        return
    }
}

# --- Define-once helper -----------------------------------------------------
function _Plan {
    param([string] $Verb, [string] $Target, [string] $Detail = '')
    Write-Host ("  [{0}] {1}" -f $Verb.PadRight(8), $Target) -ForegroundColor Yellow
    if ($Detail) { Write-Host ("           {0}" -f $Detail) -ForegroundColor DarkGray }
}

# Per-file map: filename -> definition name (must match how the initiative
# references them via /policyDefinitions/<name>).
# klz-require-tags v2 is single-tag (referenced N times by the initiative).
# The old klz-require-cost-tags has been retired — cost tags (costCenter,
# workload, env) are a subset of the required tags so a separate definition
# was pure duplication.
$customDefs = @(
    @{ File = 'require-tags.json';             Name = 'klz-require-tags'                },
    @{ File = 'cognitive-model-allowlist.json';Name = 'klz-cognitive-model-allowlist'   },
    @{ File = 'cognitive-private-only.json';   Name = 'klz-cognitive-private-only'      },
    @{ File = 'defender-for-ai-dine.json';     Name = 'klz-defender-for-ai-dine'        }
)

# --- 1. Publish (or plan to publish) each custom definition at MG scope -----
foreach ($d in $customDefs) {
    $path = Join-Path $defDir $d.File
    if (-not (Test-Path $path)) {
        Write-Warning ("Skipping missing definition file: {0}" -f $path)
        continue
    }
    _Plan 'PUT' "PolicyDefinition $($d.Name)" "from $path"

    if (-not $DryRun) {
        $defJson = Get-Content -Raw -Path $path | ConvertFrom-Json
        New-AzPolicyDefinition `
            -Name        $d.Name `
            -DisplayName $defJson.properties.displayName `
            -Description $defJson.properties.description `
            -Policy      ($defJson.properties.policyRule | ConvertTo-Json -Depth 30) `
            -Parameter   ($defJson.properties.parameters | ConvertTo-Json -Depth 30) `
            -Mode        ($defJson.properties.mode) `
            -ManagementGroupName $ManagementGroupId | Out-Null
    }
}

# --- 2. Publish (or plan to publish) the initiative ------------------------
$initName = 'klz-foundry-enterprise-baseline'
_Plan 'PUT' "PolicySetDefinition $initName" "from $initFile"

if (-not $DryRun) {
    $initJson = Get-Content -Raw -Path $initFile | ConvertFrom-Json

    # The initiative references its KLZ-custom defs via subscription().id
    # in the JSON, but at MG scope they must resolve to the MG. Rewrite the
    # policyDefinitionId values to point at the MG before publishing.
    foreach ($d in $initJson.properties.policyDefinitions) {
        if ($d.policyDefinitionId -like '*klz-*') {
            $bareName = ($d.policyDefinitionId -split '/')[-1]
            $d.policyDefinitionId = "$mgScope/providers/Microsoft.Authorization/policyDefinitions/$bareName"
        }
    }

    New-AzPolicySetDefinition `
        -Name                $initName `
        -DisplayName         $initJson.properties.displayName `
        -Description         $initJson.properties.description `
        -PolicyDefinition    ($initJson.properties.policyDefinitions | ConvertTo-Json -Depth 30) `
        -Parameter           ($initJson.properties.parameters | ConvertTo-Json -Depth 30) `
        -ManagementGroupName $ManagementGroupId | Out-Null
}

# --- 3. Assign the initiative ---------------------------------------------
# NB: PolicyAssignment name has a 24-char limit (Azure ARM). Keep it short.
$assignName = 'klz-foundry-baseline'
_Plan 'ASSIGN' "$assignName" "scope=$mgScope effect=$Mode"

if (-not $DryRun) {
    $assignmentParams = @{
        effect                  = $Mode
        logAnalyticsWorkspaceId = $LogAnalyticsWorkspaceId
    }

    $set = Get-AzPolicySetDefinition -Name $initName -ManagementGroupName $ManagementGroupId
    New-AzPolicyAssignment `
        -Name                $assignName `
        -DisplayName         'KLZ Foundry Enterprise Baseline' `
        -PolicySetDefinition $set `
        -Scope               $mgScope `
        -PolicyParameterObject $assignmentParams `
        -IdentityType        'SystemAssigned' `
        -Location            'eastus2' | Out-Null
}

Write-Host ""
Write-Host "Done. Run 'policy-compliance-report.ps1' in ~30 min for compliance signal." -ForegroundColor Green
if ($DryRun) {
    Write-Host "(DryRun was on — re-run with -DryRun:`$false to actually publish.)" -ForegroundColor Yellow
}
