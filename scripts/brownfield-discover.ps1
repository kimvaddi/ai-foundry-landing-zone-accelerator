<#
.SYNOPSIS
    Read-only discovery of AI-relevant resources for the KLZ brownfield
    remediation plan. Produces 5 CSVs under ./out/. Performs NO writes.

.PARAMETER SubscriptionIds
    Comma-separated subscription IDs to scan. Required.

.PARAMETER OutputDir
    Defaults to ./out under the repo root.

.EXAMPLE
    .\brownfield-discover.ps1 -SubscriptionIds "22222222-2222-2222-2222-222222222222,11111111-2222-3333-4444-555555555555"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionIds,
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path -Path (Join-Path $PSScriptRoot '..')
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot 'out' }
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$subs = ($SubscriptionIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($subs.Count -eq 0) { throw "No subscription IDs supplied." }

# Ensure Az.ResourceGraph is loaded.
if (-not (Get-Module -ListAvailable Az.ResourceGraph)) {
    throw "Az.ResourceGraph PowerShell module is required. Install with 'Install-Module Az.ResourceGraph -Scope CurrentUser'."
}

function Invoke-RgQuery {
    param([string] $Query)
    $all = @()
    $skipToken = $null
    do {
        $res = if ($skipToken) {
            Search-AzGraph -Query $Query -Subscription $subs -First 1000 -SkipToken $skipToken
        } else {
            Search-AzGraph -Query $Query -Subscription $subs -First 1000
        }
        if ($res) { $all += $res.Data }
        $skipToken = $res.SkipToken
    } while ($skipToken)
    return $all
}

Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host " KLZ Brownfield Discovery (read-only)" -ForegroundColor Cyan
Write-Host "   Subscriptions    : $($subs.Count)" -ForegroundColor Cyan
Write-Host "   Output           : $OutputDir" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan

# --- 1. Cognitive Services / Azure OpenAI / Foundry ------------------------
$cogQuery = @"
resources
| where type =~ 'Microsoft.CognitiveServices/accounts'
| extend kind = tostring(kind),
         publicNetworkAccess = tostring(properties.publicNetworkAccess),
         disableLocalAuth    = tobool(properties.disableLocalAuth),
         identityType        = tostring(identity.type),
         skuName             = tostring(sku.name),
         tagCostCenter       = tostring(tags['costCenter']),
         tagWorkload         = tostring(tags['workload']),
         tagEnv              = tostring(tags['env'])
| project subscriptionId, resourceGroup, name, location, kind, skuName,
          publicNetworkAccess, disableLocalAuth, identityType,
          tagCostCenter, tagWorkload, tagEnv, id
"@
$cog = Invoke-RgQuery $cogQuery
$cog | Export-Csv -Path (Join-Path $OutputDir 'brownfield-cogsvc.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  [{0,4}] Cognitive Services accounts" -f $cog.Count) -ForegroundColor Yellow

# --- 2. AI Search ----------------------------------------------------------
$searchQuery = @"
resources
| where type =~ 'Microsoft.Search/searchServices'
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess),
         disableLocalAuth    = tobool(properties.disableLocalAuth),
         identityType        = tostring(identity.type),
         skuName             = tostring(sku.name)
| project subscriptionId, resourceGroup, name, location, skuName,
          publicNetworkAccess, disableLocalAuth, identityType, id
"@
$search = Invoke-RgQuery $searchQuery
$search | Export-Csv -Path (Join-Path $OutputDir 'brownfield-search.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  [{0,4}] AI Search services" -f $search.Count) -ForegroundColor Yellow

# --- 3. API Management -----------------------------------------------------
$apimQuery = @"
resources
| where type =~ 'Microsoft.ApiManagement/service'
| extend publicNetworkAccess = tostring(properties.publicNetworkAccess),
         identityType        = tostring(identity.type),
         skuName             = tostring(sku.name)
| project subscriptionId, resourceGroup, name, location, skuName,
          publicNetworkAccess, identityType, id
"@
$apim = Invoke-RgQuery $apimQuery
$apim | Export-Csv -Path (Join-Path $OutputDir 'brownfield-apim.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  [{0,4}] API Management services" -f $apim.Count) -ForegroundColor Yellow

# --- 4. RBAC gaps — accounts where local auth is still on -----------------
$rbacGaps = $cog | Where-Object { $_.disableLocalAuth -ne $true } |
    Select-Object subscriptionId, resourceGroup, name, kind, disableLocalAuth, publicNetworkAccess, id
$rbacGaps | Export-Csv -Path (Join-Path $OutputDir 'brownfield-rbac-gaps.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  [{0,4}] Cognitive Services with local-auth still enabled" -f $rbacGaps.Count) -ForegroundColor Yellow

# --- 5. Tag gaps -----------------------------------------------------------
$tagQuery = @"
resources
| where type in~ ('Microsoft.CognitiveServices/accounts','Microsoft.Search/searchServices','Microsoft.ApiManagement/service','Microsoft.MachineLearningServices/workspaces')
| extend tagCostCenter = tostring(tags['costCenter']),
         tagWorkload   = tostring(tags['workload']),
         tagEnv        = tostring(tags['env'])
| where isnull(tagCostCenter) or tagCostCenter == ''
     or isnull(tagWorkload)   or tagWorkload   == ''
     or isnull(tagEnv)        or tagEnv        == ''
| project subscriptionId, resourceGroup, name, type, location,
          tagCostCenter, tagWorkload, tagEnv, id
"@
$tagGaps = Invoke-RgQuery $tagQuery
$tagGaps | Export-Csv -Path (Join-Path $OutputDir 'brownfield-tag-gaps.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  [{0,4}] Resources missing one of (costCenter, workload, env)" -f $tagGaps.Count) -ForegroundColor Yellow

Write-Host ""
Write-Host "Done. Open the CSVs in Excel and follow docs/Enterprise-Brownfield-Remediation-Plan.md step 2 (Triage)." -ForegroundColor Green
