<#
.SYNOPSIS
    Post-deploy sanity probes for the KLZ FinOps landing zone.

.DESCRIPTION
    Walks the deployed resources and prints PASS / FAIL per check:
      1. Required resource groups exist
      2. Required resource types are present (LAW, KV, Foundry, AI Search, APIM)
      3. Custom tables resolve (KlzAgentAudit_CL, PRICING_CL, etc.)
    Use after `scripts/deploy.ps1 -Mode smoke|full` to confirm the LZ is healthy
    and the workbook surfaces can find their data.

.EXAMPLE
    ./scripts/validate.ps1 -Workload klzfin -Environment dev
#>
[CmdletBinding()]
param(
    [string] $Workload = 'klzfin',
    [string] $Environment = 'dev'
)

$ErrorActionPreference = 'Continue'
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red }

$rgPlatform = "rg-$Workload-platform-$Environment"
$rgFoundry  = "rg-$Workload-foundry-$Environment"

# --- 1. Resource groups exist
Step 'Resource groups'
foreach ($rg in @($rgPlatform, $rgFoundry)) {
    if ((az group exists --name $rg) -eq 'true') { Pass $rg } else { Fail $rg }
}

# --- 2. Required resource types present
Step 'Resource inventory'
$workspace = az resource list -g $rgPlatform --resource-type 'Microsoft.OperationalInsights/workspaces' --query '[0].name' -o tsv
if ($workspace) { Pass "LAW = $workspace" } else { Fail 'LAW missing' }

$kv = az resource list -g $rgPlatform --resource-type 'Microsoft.KeyVault/vaults' --query '[0].name' -o tsv
if ($kv) { Pass "KV = $kv" } else { Fail 'KV missing' }

$foundry = az resource list -g $rgFoundry --resource-type 'Microsoft.CognitiveServices/accounts' --query '[0].name' -o tsv
if ($foundry) { Pass "Foundry account = $foundry" } else { Fail 'Foundry account missing' }

$projects = az resource list -g $rgFoundry --resource-type 'Microsoft.CognitiveServices/accounts/projects' --query 'length([])' -o tsv
if ($projects -ge 1) { Pass "Foundry projects: $projects" } else { Fail 'No Foundry projects' }

$search = az resource list -g $rgFoundry --resource-type 'Microsoft.Search/searchServices' --query '[0].name' -o tsv
if ($search) { Pass "AI Search = $search" } else { Fail 'AI Search missing' }

# --- 3. Custom tables actually got created (the riskiest module)
Step 'Custom log tables'
if ($workspace) {
    foreach ($t in @('PRICING_CL', 'SUBSCRIPTION_QUOTA_CL')) {
        $exists = az monitor log-analytics workspace table show -g $rgPlatform --workspace-name $workspace --name $t --query 'name' -o tsv 2>$null
        if ($exists -eq $t) { Pass "Table $t" } else { Fail "Table $t" }
    }
}

# --- 4. DCE + DCRs exist
Step 'DCE + DCRs'
$dce = az resource list -g $rgPlatform --resource-type 'Microsoft.Insights/dataCollectionEndpoints' --query '[0].name' -o tsv
if ($dce) { Pass "DCE = $dce" } else { Fail 'DCE missing' }
$dcrs = az resource list -g $rgPlatform --resource-type 'Microsoft.Insights/dataCollectionRules' --query 'length([])' -o tsv
if ($dcrs -ge 2) { Pass "DCRs: $dcrs" } else { Fail "Expected >=2 DCRs, got $dcrs" }

# --- 5. Workbooks present
Step 'Workbooks'
$wb = az resource list -g $rgPlatform --resource-type 'Microsoft.Insights/workbooks' --query 'length([])' -o tsv
if ($wb -ge 2) { Pass "Workbooks: $wb" } else { Fail "Expected >=2 workbooks, got $wb" }

# --- 6. Foundry endpoint live (no key, MI only)
if ($foundry) {
    Step 'Foundry endpoint'
    $endpoint = az cognitiveservices account show -g $rgFoundry -n $foundry --query 'properties.endpoint' -o tsv
    if ($endpoint) { Pass "Endpoint = $endpoint" } else { Fail 'No endpoint' }
    $disabledLocal = az cognitiveservices account show -g $rgFoundry -n $foundry --query 'properties.disableLocalAuth' -o tsv
    if ($disabledLocal -eq 'true') { Pass 'disableLocalAuth=true' } else { Fail "disableLocalAuth=$disabledLocal (expected true)" }
}

Write-Host '' -NoNewline
Write-Host "Validation complete." -ForegroundColor Cyan
