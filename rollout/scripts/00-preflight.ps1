<#
.SYNOPSIS
    Preflight check before running any KLZ rollout step. Verifies sign-in,
    subscription, required Az / az CLI versions, and the role assignments
    the rollout will need at each scope.

.PARAMETER ConfigPath
    Path to a customer.psd1 (see ../config/customer.psd1.template).

.EXAMPLE
    .\00-preflight.ps1 -ConfigPath ..\config\customer.psd1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------- helpers
function _Section($t) { Write-Host ""; Write-Host "== $t ==" -ForegroundColor Cyan }
function _Ok      ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function _Warn    ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function _Fail    ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:_failed = $true }
$script:_failed = $false

# ------------------------------------------------------------------- config
if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Import-PowerShellDataFile -Path $ConfigPath
foreach ($req in 'TenantId','SubscriptionId','ParentManagementGroupId','AiLandingZoneManagementGroupId','LogAnalyticsWorkspaceId','PolicyEffect') {
    if (-not $cfg.$req -or $cfg.$req -like '<*') { throw "Config missing/placeholder: $req" }
}
_Section "Config loaded"
_Ok "TenantId        = $($cfg.TenantId)"
_Ok "SubscriptionId  = $($cfg.SubscriptionId)"
_Ok "ParentMG        = $($cfg.ParentManagementGroupId)"
_Ok "Target MG       = $($cfg.AiLandingZoneManagementGroupId)"
_Ok "PolicyEffect    = $($cfg.PolicyEffect)"

# ------------------------------------------------------------------- tooling
_Section "Tooling"
try {
    $azVer = (az version --output json | ConvertFrom-Json).'azure-cli'
    if ([version]$azVer -lt [version]'2.60.0') { _Fail "az CLI $azVer < 2.60.0" } else { _Ok "az CLI $azVer" }
} catch { _Fail "az CLI not installed or not on PATH" }
$bicepRaw = az bicep version 2>&1 | Out-String
$bicepVer = ($bicepRaw | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).Matches.Value
if ($bicepVer) { _Ok "bicep $bicepVer" } else { _Warn "bicep not installed — run 'az bicep install'" }
$azMod = Get-Module -ListAvailable -Name Az.Resources | Sort-Object Version -Descending | Select-Object -First 1
if (-not $azMod -or $azMod.Version -lt [version]'6.0.0') {
    _Fail "Az.Resources >= 6.0.0 required. Install: Install-Module Az -Scope CurrentUser"
} else { _Ok "Az.Resources $($azMod.Version)" }

# ------------------------------------------------------------------- account
_Section "Signed-in account"
$acct = az account show --output json 2>$null | ConvertFrom-Json
if (-not $acct) { _Fail "Not signed in. Run: az login --tenant $($cfg.TenantId)"; return }
_Ok "User     $($acct.user.name)"
_Ok "Tenant   $($acct.tenantId)"
_Ok "SubId    $($acct.id)"
if ($acct.tenantId -ne $cfg.TenantId)         { _Fail "Active tenant != cfg.TenantId. Run: az login --tenant $($cfg.TenantId)" }
if ($acct.id      -ne $cfg.SubscriptionId)    { _Fail "Active sub  != cfg.SubscriptionId. Run: az account set --subscription $($cfg.SubscriptionId)" }
$me = az ad signed-in-user show --query id -o tsv

# ------------------------------------------------------------------- MG access
_Section "Management-group access"
$parentScope = "/providers/Microsoft.Management/managementGroups/$($cfg.ParentManagementGroupId)"
$mgExists = az account management-group show --name $cfg.ParentManagementGroupId --output json 2>$null
if (-not $mgExists) {
    _Fail "Parent MG '$($cfg.ParentManagementGroupId)' not found OR caller cannot read it."
    _Warn "If you are tenant admin, you may need Management Group Reader at the parent."
} else {
    _Ok "Parent MG visible"
    $mgRoles = az role assignment list --assignee-object-id $me --scope $parentScope --query "[].roleDefinitionName" -o tsv
    $needed  = 'Management Group Contributor','Owner','Resource Policy Contributor'
    $have    = $mgRoles | Where-Object { $_ -in $needed -or $_ -eq 'Contributor' }
    if (-not $have) {
        _Fail "Caller lacks any of: $($needed -join ', ') at parent MG. Required to create child MG + assign policy."
    } else {
        _Ok "Roles at parent MG: $($have -join ', ')"
    }
}

# ------------------------------------------------------------------- LAW
_Section "Log Analytics workspace"
$law = az resource show --ids $cfg.LogAnalyticsWorkspaceId --output json 2>$null
if (-not $law) { _Fail "LAW not reachable: $($cfg.LogAnalyticsWorkspaceId)" }
else           { _Ok  "LAW reachable" }

# ------------------------------------------------------------------- result
_Section "Result"
if ($script:_failed) {
    Write-Host "  Preflight FAILED. Fix the [FAIL] items above before continuing." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  Preflight PASSED. Safe to proceed to 10-mg-hierarchy-ensure.ps1." -ForegroundColor Green
}
