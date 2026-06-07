<#
.SYNOPSIS
  Publish the AI Foundry Landing Zone Accelerator as an Azure Template Spec
  in the current (or specified) subscription, with an embedded
  createUiDefinition.json so customers get the full guided wizard WITHOUT
  the "Do you trust this template?" trust banner.

.DESCRIPTION
  Template Specs are first-class Azure resources hosted in the customer's
  own tenant. Because the template is owned by the customer's tenant (not
  fetched from raw.githubusercontent.com), the Azure Portal does NOT show
  the "this author's code has not been verified by Microsoft" banner —
  Portal treats the customer as the publisher of their own template.

  This script:
    1. Validates the bundled artifacts (mainTemplate + UI definition + param parity).
    2. Ensures a hosting resource group exists.
    3. Creates a new Template Spec version (uses --Force to overwrite same-version uploads).
    4. Emits the Portal "Deploy" URL the customer can bookmark / share.

  The Template Spec is created with three artifacts:
    - mainTemplate  = deploy/azuredeploy-full.json   (self-contained, no GitHub fetches)
    - uiFormDefinition = deploy/createUiDefinition.json
    - description / displayName for the Portal "Templates" blade

.PARAMETER SubscriptionId
  Subscription to host the Template Spec in. Required.

.PARAMETER ResourceGroupName
  Resource group to create the Template Spec in. Created if missing.
  Default: 'rg-ai-foundry-templatespec'.

.PARAMETER Location
  Azure region for the hosting RG. Template Specs are global (the RG region
  only controls where the Template Spec metadata is stored). Default: 'eastus2'.

.PARAMETER Name
  Template Spec name. Default: 'ai-foundry-landing-zone'.

.PARAMETER Version
  Semver version. Use a new version every publish so consumers can pin.
  Default: today's date stamp e.g. '2026.06.07'.

.PARAMETER DisplayName
  Friendly name shown on the Portal Templates blade and Deploy form.

.EXAMPLE
  ./scripts/publish-templatespec.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
  ./scripts/publish-templatespec.ps1 `
    -SubscriptionId <sub> `
    -ResourceGroupName rg-platform-templatespecs `
    -Location swedencentral `
    -Name ai-foundry-lz-finops `
    -Version 2026.06.07
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SubscriptionId,

  [string]$ResourceGroupName = 'rg-ai-foundry-templatespec',
  [string]$Location           = 'eastus2',
  [string]$Name               = 'ai-foundry-landing-zone',
  [string]$Version            = (Get-Date -Format 'yyyy.MM.dd'),
  [string]$DisplayName        = 'AI Foundry Landing Zone Accelerator (FinOps Edition)'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve repo-relative artifact paths regardless of where the script is invoked from
$repoRoot     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mainTemplate = Join-Path $repoRoot 'deploy/azuredeploy-full.json'
$uiDefinition = Join-Path $repoRoot 'deploy/createUiDefinition.json'

Write-Host ''
Write-Host '=== AI Foundry Landing Zone — Template Spec publisher ===' -ForegroundColor Cyan
Write-Host "  Subscription: $SubscriptionId"
Write-Host "  RG:           $ResourceGroupName ($Location)"
Write-Host "  Spec:         $Name @ v$Version"
Write-Host "  Main:         $mainTemplate"
Write-Host "  UI form:      $uiDefinition"
Write-Host ''

# ---- 1. Pre-flight ----------------------------------------------------------
Write-Host '[1/5] Validating artifacts...' -ForegroundColor Yellow
foreach ($p in @($mainTemplate, $uiDefinition)) {
  if (-not (Test-Path $p)) { throw "Required artifact missing: $p" }
}
$mainSize = (Get-Item $mainTemplate).Length
if ($mainSize -gt 4MB) { throw "Main template is $([math]::Round($mainSize/1MB,2)) MB; Template Spec limit is 4 MB." }
$uiSize = (Get-Item $uiDefinition).Length

# Strict-parse both files
try { $main = Get-Content $mainTemplate -Raw | ConvertFrom-Json -Depth 100 }
catch { throw "mainTemplate failed JSON parse: $_" }
try { $ui   = Get-Content $uiDefinition -Raw | ConvertFrom-Json -Depth 100 }
catch { throw "uiFormDefinition failed JSON parse: $_" }

# Verify createUiDefinition output -> template param parity (every UI output must be a known param)
$mainParams = $main.parameters.PSObject.Properties.Name
$uiOutputs  = $ui.parameters.outputs.PSObject.Properties.Name
$unknown    = $uiOutputs | Where-Object { $_ -notin $mainParams }
if ($unknown) { throw "UI definition emits outputs not present in mainTemplate: $($unknown -join ', ')" }
$missingReq = $mainParams | Where-Object {
  ($main.parameters.$_.PSObject.Properties.Name -notcontains 'defaultValue') -and ($_ -notin $uiOutputs)
}
if ($missingReq) { throw "Required mainTemplate params not supplied by UI: $($missingReq -join ', ')" }
Write-Host "      mainTemplate: $([math]::Round($mainSize/1KB,1)) KB, $($mainParams.Count) params" -ForegroundColor DarkGray
Write-Host "      UI form:      $([math]::Round($uiSize/1KB,1))   KB, $($uiOutputs.Count) outputs" -ForegroundColor DarkGray
Write-Host "      Param parity: OK" -ForegroundColor Green

# ---- 2. Az PowerShell context ----------------------------------------------
Write-Host '[2/5] Setting Az PowerShell context...' -ForegroundColor Yellow
if (-not (Get-Module -ListAvailable Az.Resources)) {
  throw 'Az.Resources module not installed. Run: Install-Module Az -Repository PSGallery -Scope CurrentUser'
}
Import-Module Az.Resources -ErrorAction Stop
$ctx = Get-AzContext
if (-not $ctx) {
  Write-Host '      No Az context — running Connect-AzAccount...' -ForegroundColor DarkGray
  Connect-AzAccount -Subscription $SubscriptionId | Out-Null
} elseif ($ctx.Subscription.Id -ne $SubscriptionId) {
  Set-AzContext -Subscription $SubscriptionId | Out-Null
}
$ctx = Get-AzContext
Write-Host "      Account: $($ctx.Account.Id)" -ForegroundColor DarkGray
Write-Host "      Tenant:  $($ctx.Tenant.Id)" -ForegroundColor DarkGray

# ---- 3. Hosting resource group ---------------------------------------------
Write-Host "[3/5] Ensuring resource group '$ResourceGroupName' exists..." -ForegroundColor Yellow
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
  $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{
    purpose      = 'template-spec-host'
    workload     = 'ai-foundry-landing-zone'
    managedBy    = 'klz-accelerator'
  }
  Write-Host "      Created $($rg.ResourceId)" -ForegroundColor Green
} else {
  Write-Host "      Exists  $($rg.ResourceId)" -ForegroundColor DarkGray
}

# ---- 4. Publish the Template Spec version ----------------------------------
Write-Host "[4/5] Publishing Template Spec '$Name' v$Version..." -ForegroundColor Yellow
$specVersion = New-AzTemplateSpec `
  -Name              $Name `
  -Version           $Version `
  -ResourceGroupName $ResourceGroupName `
  -Location          $Location `
  -DisplayName       $DisplayName `
  -Description       'Dual-stack (Bicep/Terraform) Azure landing zone for Microsoft Foundry / Azure OpenAI with FinOps showback, APIM AI Gateway governance, and content safety. Self-contained template — no external fetches at deploy time.' `
  -VersionDescription "Published $(Get-Date -Format 'yyyy-MM-dd HH:mm') from kimvaddi/ai-foundry-landing-zone-accelerator" `
  -TemplateFile      $mainTemplate `
  -UIFormDefinitionFile $uiDefinition `
  -Force
Write-Host "      Spec version ID: $($specVersion.Id)" -ForegroundColor Green

# Compose the FULL version resource ID — what Portal expects.
# New-AzTemplateSpec returns the parent spec; Portal deeplinks need /versions/<v> appended.
$versionResourceId = "$($specVersion.Id)/versions/$Version"

# ---- 5. Emit Portal Deploy URL ---------------------------------------------
Write-Host '[5/5] Generating Portal Deploy URL...' -ForegroundColor Yellow
# Portal deeplink for Template Spec deployment. The embedded UIFormDefinition
# is auto-picked up by Portal — no separate createUIDefinitionUri query param.
$encodedSpecId = [uri]::EscapeDataString($versionResourceId)
$portalUrl     = "https://portal.azure.com/#create/Microsoft.Template/templateSpecVersionId/$encodedSpecId"

Write-Host ''
Write-Host '=== DONE ===' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Template Spec published. Share this link with the customer:' -ForegroundColor Green
Write-Host ''
Write-Host $portalUrl -ForegroundColor White
Write-Host ''
Write-Host 'What the customer will see:' -ForegroundColor Cyan
Write-Host '  - No "Do you trust this template?" banner (Portal treats them as the publisher)'
Write-Host '  - The same 8-step wizard (Basics -> Blueprint -> ... -> RBAC -> Review)'
Write-Host '  - Resources deploy into their own subscription as usual'
Write-Host ''
Write-Host 'To re-publish (e.g. after a fix), re-run this script with the same Name and either:' -ForegroundColor Cyan
Write-Host "  - Same -Version  -> overwrites in place (the same Portal URL keeps working)"
Write-Host "  - New  -Version  -> creates a new version; update the URL above with the new versionId"
Write-Host ''
