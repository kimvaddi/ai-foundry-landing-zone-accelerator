###############################################################################
# parity-diff.ps1 — Cross-stack parity test for klz-accelerator-finops
#
# For a given blueprint, runs both stacks' "what-if" equivalent and diffs the
# resource set. Fails non-zero if the symmetric difference (after filtering
# known-acceptable cross-stack differences) is non-empty.
#
# Usage:
#   ./scripts/parity-diff.ps1 -Blueprint smoke
#   ./scripts/parity-diff.ps1 -Blueprint poc-standalone-spoke -SubscriptionId ba89cfed-...
#
# Exit codes:
#   0 — parity OK (no unexpected drift)
#   1 — drift detected beyond the allowlist
#   2 — environment / tooling error
#
# Allowlist of known-acceptable cross-stack differences lives in:
#   docs/parity-allowlist.json
#
# Output:
#   - Compact diff to stdout (and CI annotations)
#   - Detailed per-resource JSON dumps to artifacts/parity/<blueprint>/
###############################################################################

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('smoke', 'poc-standalone-spoke', 'poc-hub-connected',
               'prod-standalone-with-fw', 'prod-hub-connected',
               'full', 'stage-b-toggles')]
  [string]$Blueprint,

  [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,
  [string]$Location = 'eastus2',
  [string]$RgSuffix = "-parity-$(Get-Date -Format 'yyyyMMddHHmm')",
  [string]$AllowlistPath = "$PSScriptRoot/../docs/parity-allowlist.json",
  [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot/.."

if (-not $SubscriptionId) {
  Write-Error "SubscriptionId required (pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID)"
  exit 2
}

#-----------------------------------------------------------------------------
# 1. Resolve paths for the chosen blueprint
#-----------------------------------------------------------------------------

$paths = switch ($Blueprint) {
  'smoke'                   { @{ tf = 'blueprints/smoke/smoke.tfvars';                     bicep = 'blueprints/smoke/smoke.bicepparam' } }
  'poc-standalone-spoke'    { @{ tf = 'blueprints/poc-standalone-spoke/poc-standalone-spoke.tfvars'; bicep = 'blueprints/poc-standalone-spoke/poc-standalone-spoke.bicepparam' } }
  'poc-hub-connected'       { @{ tf = 'blueprints/poc-hub-connected/poc-hub-connected.tfvars';     bicep = 'blueprints/poc-hub-connected/poc-hub-connected.bicepparam' } }
  'prod-standalone-with-fw' { @{ tf = 'blueprints/prod-standalone-with-fw/prod-standalone-with-fw.tfvars'; bicep = 'blueprints/prod-standalone-with-fw/prod-standalone-with-fw.bicepparam' } }
  'prod-hub-connected'      { @{ tf = 'blueprints/prod-hub-connected/prod-hub-connected.tfvars';   bicep = 'blueprints/prod-hub-connected/prod-hub-connected.bicepparam' } }
  'full'                    { @{ tf = 'parameters/full.tfvars';                                    bicep = 'parameters/full.bicepparam' } }
  'stage-b-toggles'         { @{ tf = 'parameters/stage-b-toggles.tfvars';                         bicep = 'parameters/stage-b-toggles.bicepparam' } }
}

$tfPath    = Join-Path $repoRoot "infra/terraform/$($paths.tf)"
$bicepPath = Join-Path $repoRoot "infra/bicep/$($paths.bicep)"

if (-not (Test-Path $tfPath))    { Write-Error "TF vars not found: $tfPath";    exit 2 }
if (-not (Test-Path $bicepPath)) { Write-Error "bicepparam not found: $bicepPath"; exit 2 }

$artifactDir = Join-Path $repoRoot "artifacts/parity/$Blueprint"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

Write-Host "==== parity-diff: $Blueprint ====" -ForegroundColor Cyan
Write-Host "TF vars:    $tfPath"
Write-Host "Bicep param: $bicepPath"
Write-Host "Artifacts:  $artifactDir"
Write-Host ""

#-----------------------------------------------------------------------------
# 2. Generate Terraform plan JSON
#-----------------------------------------------------------------------------

$tfDir = Join-Path $repoRoot "infra/terraform"
Push-Location $tfDir
try {
  Write-Host "==> terraform plan ($Blueprint)" -ForegroundColor Yellow

  # Locate terraform binary
  $tfExe = (Get-Command terraform -ErrorAction SilentlyContinue).Source
  if (-not $tfExe) {
    $tfExe = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe\terraform.exe"
  }
  if (-not (Test-Path $tfExe)) { Write-Error "terraform binary not found"; exit 2 }

  # Generate ephemeral creds for plan
  $sshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpwfee+5R5OboUx7eifKqYKW/WvT6XjRW1x18NxcVvk parity@klz-finops'
  $dummyPwd = 'ParityP@ssw0rd1234!QA'

  & $tfExe init -backend=false -input=false 2>&1 | Out-Null

  $planPath = Join-Path $artifactDir 'tfplan'
  & $tfExe plan `
    "-var-file=$($paths.tf)" `
    "-var=subscription_id=$SubscriptionId" `
    "-var=rg_suffix=$RgSuffix" `
    "-var=jumpvm_admin_password=$dummyPwd" `
    "-var=buildvm_ssh_public_key=$sshKey" `
    -lock=false -input=false -no-color `
    "-out=$planPath" 2>&1 | Out-Null

  if ($LASTEXITCODE -ne 0) { Write-Error "terraform plan failed"; exit 2 }

  $tfJsonPath = Join-Path $artifactDir 'tf-plan.json'
  & $tfExe show -json $planPath > $tfJsonPath
  if ($LASTEXITCODE -ne 0) { Write-Error "terraform show -json failed"; exit 2 }
  Write-Host "    saved $tfJsonPath"
} finally {
  Pop-Location
}

#-----------------------------------------------------------------------------
# 3. Generate Bicep what-if JSON
#-----------------------------------------------------------------------------

Write-Host "==> az deployment sub what-if ($Blueprint)" -ForegroundColor Yellow

$azCmd = (Get-Command az -ErrorAction SilentlyContinue).Source
if (-not $azCmd) {
  $azCmd = (Get-ChildItem "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin" -Filter az.cmd -EA SilentlyContinue | Select -First 1).FullName
}
if (-not $azCmd) { Write-Error "az CLI not found"; exit 2 }

$bicepJsonPath = Join-Path $artifactDir 'bicep-whatif.json'
$mainBicep = Join-Path $repoRoot 'infra/bicep/main.bicep'

& $azCmd deployment sub what-if `
  --location $Location `
  --name "parity-$Blueprint-$(Get-Date -Format 'yyyyMMddHHmm')" `
  --template-file $mainBicep `
  --parameters $bicepPath `
  --no-pretty-print `
  --subscription $SubscriptionId `
  -o json > $bicepJsonPath 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Warning "az what-if returned $LASTEXITCODE — output may be diagnostic"
  Get-Content $bicepJsonPath | Select-Object -First 30
}
Write-Host "    saved $bicepJsonPath"

#-----------------------------------------------------------------------------
# 4. Normalize both to {type, name} tuples
#-----------------------------------------------------------------------------

Write-Host "==> normalize + diff" -ForegroundColor Yellow

function ConvertTo-AzureType($tfType) {
  # azurerm_log_analytics_workspace → Microsoft.OperationalInsights/workspaces, etc.
  # This is a partial map covering the resource types our engine produces.
  # Extend as new resource types are introduced.
  switch -Wildcard ($tfType) {
    'azurerm_resource_group'                    { 'Microsoft.Resources/resourceGroups' }
    'azurerm_virtual_network'                   { 'Microsoft.Network/virtualNetworks' }
    'azurerm_subnet'                            { 'Microsoft.Network/virtualNetworks/subnets' }
    'azurerm_network_security_group'            { 'Microsoft.Network/networkSecurityGroups' }
    'azurerm_subnet_network_security_group_association' { $null }   # Not a real Azure resource — wire-up only
    'azurerm_subnet_route_table_association'    { $null }
    'azurerm_private_dns_zone'                  { 'Microsoft.Network/privateDnsZones' }
    'azurerm_private_dns_zone_virtual_network_link' { 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' }
    'azurerm_private_endpoint'                  { 'Microsoft.Network/privateEndpoints' }
    'azurerm_public_ip'                         { 'Microsoft.Network/publicIPAddresses' }
    'azurerm_log_analytics_workspace'           { 'Microsoft.OperationalInsights/workspaces' }
    'azurerm_log_analytics_solution'            { 'Microsoft.OperationsManagement/solutions' }
    'azurerm_application_insights'              { 'Microsoft.Insights/components' }
    'azurerm_key_vault'                         { 'Microsoft.KeyVault/vaults' }
    'azurerm_key_vault_secret'                  { 'Microsoft.KeyVault/vaults/secrets' }
    'azurerm_key_vault_access_policy'           { $null }   # Wire-up only
    'azurerm_role_assignment'                   { 'Microsoft.Authorization/roleAssignments' }
    'azurerm_cognitive_account'                 { 'Microsoft.CognitiveServices/accounts' }
    'azurerm_cognitive_deployment'              { 'Microsoft.CognitiveServices/accounts/deployments' }
    'azurerm_search_service'                    { 'Microsoft.Search/searchServices' }
    'azurerm_api_management'                    { 'Microsoft.ApiManagement/service' }
    'azurerm_api_management_api'                { 'Microsoft.ApiManagement/service/apis' }
    'azurerm_api_management_product'            { 'Microsoft.ApiManagement/service/products' }
    'azurerm_api_management_product_api'        { $null }   # Wire-up
    'azurerm_storage_account'                   { 'Microsoft.Storage/storageAccounts' }
    'azurerm_storage_container'                 { 'Microsoft.Storage/storageAccounts/blobServices/containers' }
    'azurerm_cosmosdb_account'                  { 'Microsoft.DocumentDB/databaseAccounts' }
    'azurerm_linux_virtual_machine'             { 'Microsoft.Compute/virtualMachines' }
    'azurerm_windows_virtual_machine'           { 'Microsoft.Compute/virtualMachines' }
    'azurerm_network_interface'                 { 'Microsoft.Network/networkInterfaces' }
    'azurerm_bastion_host'                      { 'Microsoft.Network/bastionHosts' }
    'azurerm_application_gateway'               { 'Microsoft.Network/applicationGateways' }
    'azurerm_monitor_data_collection_rule'      { 'Microsoft.Insights/dataCollectionRules' }
    'azurerm_monitor_data_collection_endpoint'  { 'Microsoft.Insights/dataCollectionEndpoints' }
    'azurerm_monitor_data_collection_rule_association' { $null }   # Wire-up
    'azurerm_monitor_diagnostic_setting'        { 'Microsoft.Insights/diagnosticSettings' }
    'azurerm_monitor_scheduled_query_rules_alert_v2' { 'Microsoft.Insights/scheduledQueryRules' }
    'azurerm_monitor_metric_alert'              { 'Microsoft.Insights/metricAlerts' }
    'azurerm_monitor_action_group'              { 'Microsoft.Insights/actionGroups' }
    'azurerm_application_insights_workbook'     { 'Microsoft.Insights/workbooks' }
    'azapi_resource'                            { $null }   # azapi resources need per-resource type extraction
    'azapi_resource_action'                     { $null }   # Lifecycle hook, not a resource
    'azapi_update_resource'                     { $null }
    'time_sleep'                                { $null }
    'random_string'                             { $null }
    'random_id'                                 { $null }
    'random_password'                           { $null }
    'tls_private_key'                           { $null }
    'modtm_telemetry'                           { $null }   # AVM telemetry beacon, not deployed
    default { $null }
  }
}

# --- Parse TF plan ---
$tfPlan = Get-Content $tfJsonPath -Raw | ConvertFrom-Json
$tfResources = @()
function Walk-Module($mod) {
  foreach ($r in $mod.resources) {
    $azType = ConvertTo-AzureType $r.type
    if (-not $azType -and $r.type -eq 'azapi_resource') {
      $azType = $r.values.type -replace '@.*$',''   # 'Microsoft.X/y@2024' → 'Microsoft.X/y'
    }
    if ($azType) {
      $script:tfResources += [PSCustomObject]@{
        Type = $azType
        Address = $r.address
        Stack = 'tf'
      }
    }
  }
  foreach ($child in $mod.child_modules) { Walk-Module $child }
}
Walk-Module $tfPlan.planned_values.root_module

# --- Parse Bicep what-if ---
$bicepWhatIf = Get-Content $bicepJsonPath -Raw | ConvertFrom-Json
$bicepResources = @()

# Resource ID format examples:
#   /subscriptions/{sub}/resourceGroups/{rg}/providers/{ns}/{type}/{name}
#   /subscriptions/{sub}/resourceGroups/{rg}/providers/{ns}/{type}/{name}/{subType}/{subName}
#   /subscriptions/{sub}/providers/Microsoft.Resources/deployments/{name}
# Type = namespace + alternating segments after, dropping the name segments.
function Get-ResourceTypeFromId([string]$id) {
  # Subscription-scope RG: /subscriptions/{sub}/resourceGroups/{name}
  if ($id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+$') {
    return 'Microsoft.Resources/resourceGroups'
  }
  # Find the LAST /providers/ segment — nested children (e.g. diagnosticSettings)
  # are scoped to their parent via /providers/Microsoft.Insights/diagnosticSettings/...
  $lastProvidersIdx = $id.LastIndexOf('/providers/')
  if ($lastProvidersIdx -lt 0) { return $null }
  $tail = $id.Substring($lastProvidersIdx + '/providers/'.Length)
  $parts = $tail -split '/'
  if ($parts.Count -lt 2) { return $null }
  # parts[0]=namespace, parts[1]=topType, parts[2]=topName, parts[3]=subType, parts[4]=subName, ...
  $typeSegments = @($parts[0])
  for ($i = 1; $i -lt $parts.Count; $i += 2) {
    $typeSegments += $parts[$i]
  }
  return ($typeSegments -join '/')
}

foreach ($change in $bicepWhatIf.changes) {
  if ($change.changeType -in 'Create','Modify','Deploy') {
    $type = Get-ResourceTypeFromId $change.resourceId
    if ($type) {
      $bicepResources += [PSCustomObject]@{
        Type = $type
        Address = $change.resourceId
        Stack = 'bicep'
      }
    }
  }
}

#-----------------------------------------------------------------------------
# 5. Diff (counts by resource type)
#-----------------------------------------------------------------------------

$tfCounts = $tfResources | Group-Object Type | ForEach-Object { @{ $_.Name = $_.Count } } | ForEach-Object { $_ }
$bicepCounts = $bicepResources | Group-Object Type | ForEach-Object { @{ $_.Name = $_.Count } } | ForEach-Object { $_ }

$tfTable = @{}
$tfResources | Group-Object Type | ForEach-Object { $tfTable[$_.Name] = $_.Count }
$bicepTable = @{}
$bicepResources | Group-Object Type | ForEach-Object { $bicepTable[$_.Name] = $_.Count }

$allTypes = ($tfTable.Keys + $bicepTable.Keys) | Select-Object -Unique | Sort-Object

# Load allowlist
$allowlist = @{}
if (Test-Path $AllowlistPath) {
  $allowlistRaw = Get-Content $AllowlistPath -Raw | ConvertFrom-Json
  $blueprintAllow = $allowlistRaw.$Blueprint
  if ($blueprintAllow) {
    foreach ($k in $blueprintAllow.PSObject.Properties.Name) {
      $allowlist[$k] = $blueprintAllow.$k
    }
  }
}

$diffRows = @()
foreach ($t in $allTypes) {
  $tfN = if ($tfTable.ContainsKey($t)) { $tfTable[$t] } else { 0 }
  $bcN = if ($bicepTable.ContainsKey($t)) { $bicepTable[$t] } else { 0 }
  $delta = $tfN - $bcN
  $allowedDelta = if ($allowlist.ContainsKey($t)) { $allowlist[$t] } else { 0 }
  $unexplained = $delta - $allowedDelta
  $diffRows += [PSCustomObject]@{
    Type = $t
    TF = $tfN
    Bicep = $bcN
    Delta = $delta
    Allowed = $allowedDelta
    Unexplained = $unexplained
  }
}

$diffRows | Format-Table -AutoSize -Property Type,TF,Bicep,Delta,Allowed,Unexplained | Out-String -Width 200 | Write-Host

$problematic = $diffRows | Where-Object { $_.Unexplained -ne 0 }
if ($problematic) {
  Write-Host ""
  Write-Host "Unexplained drift in $($problematic.Count) resource type(s):" -ForegroundColor Red
  $problematic | Format-Table -AutoSize -Property Type,TF,Bicep,Delta,Allowed,Unexplained | Out-String -Width 200 | Write-Host
  Write-Host "To accept this delta, add it to $AllowlistPath under '$Blueprint':" -ForegroundColor Yellow
  Write-Host '{ "<resource-type>": <tf-count - bicep-count> }' -ForegroundColor Yellow
  if (-not $KeepArtifacts) { Remove-Item -Recurse -Force $artifactDir -EA SilentlyContinue }
  exit 1
}

Write-Host ""
Write-Host "==> parity OK (all deltas within allowlist)" -ForegroundColor Green
if (-not $KeepArtifacts) { Remove-Item -Recurse -Force $artifactDir -EA SilentlyContinue }
exit 0
