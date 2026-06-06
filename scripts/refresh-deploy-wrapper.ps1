#requires -Version 7.0
<#
.SYNOPSIS
  Rebuild deploy/azuredeploy.json (the thin wrapper) from deploy/azuredeploy-full.json.

.DESCRIPTION
  The Azure Portal's #create deeplink fetches templates browser-side and is unreliable
  above ~1 MB. Our full template is 1.7 MB, so we use the linked-template pattern:
  the wrapper (small) is what the Portal fetches; the wrapper submits a nested
  deployment that ARM fetches server-side from azuredeploy-full.json.

  This script regenerates the wrapper:
    1. Reads deploy/azuredeploy-full.json
    2. Copies the parameters block verbatim
    3. Builds a single Microsoft.Resources/deployments resource that forwards
       every parameter to the full template via templateLink.uri
    4. Adds output passthroughs for every inner-template output (so validation
       messages and resource IDs surface in the wrapper's deployment summary)

  Run this any time deploy/azuredeploy-full.json changes (after `az bicep build`).

.PARAMETER FullTemplateRawUri
  The raw.githubusercontent.com URL where ARM will fetch azuredeploy-full.json
  at deploy time. Must match where you actually push the file. Defaults to the
  kimvaddi/ai-foundry-landing-zone-accelerator main branch.

.PARAMETER NestedDeploymentName
  Name of the nested deployment inside the wrapper. Shows up in the portal's
  deployment history. Defaults to 'klz-foundry-landing-zone'.

.EXAMPLE
  ./scripts/refresh-deploy-wrapper.ps1

.EXAMPLE
  ./scripts/refresh-deploy-wrapper.ps1 -FullTemplateRawUri 'https://raw.githubusercontent.com/myfork/my-repo/main/deploy/azuredeploy-full.json'
#>
[CmdletBinding()]
param(
    [string] $FullTemplateRawUri = 'https://raw.githubusercontent.com/kimvaddi/ai-foundry-landing-zone-accelerator/main/deploy/azuredeploy-full.json',
    [string] $NestedDeploymentName = 'klz-foundry-landing-zone'
)

$ErrorActionPreference = 'Stop'

# Resolve repo root from script location
$repoRoot   = Split-Path -Parent $PSScriptRoot
$fullPath   = Join-Path $repoRoot 'deploy/azuredeploy-full.json'
$wrapPath   = Join-Path $repoRoot 'deploy/azuredeploy.json'

if (-not (Test-Path $fullPath)) {
    throw "Full template not found at $fullPath. Run 'az bicep build --file infra/bicep/main.bicep' and copy infra/bicep/main.json -> deploy/azuredeploy-full.json first."
}

Write-Host "Reading full template..." -ForegroundColor Cyan
$src = Get-Content $fullPath -Raw | ConvertFrom-Json -Depth 100

# Forwarded parameters: { paramName: { value: "[parameters('paramName')]" } }
$forwarded = [ordered]@{}
foreach ($p in $src.parameters.PSObject.Properties | Sort-Object Name) {
    $forwarded[$p.Name] = [ordered]@{ value = "[parameters('$($p.Name)')]" }
}

# Output passthroughs: every output from the inner template, referenced via reference()
$outputs = [ordered]@{}
foreach ($o in $src.outputs.PSObject.Properties | Sort-Object Name) {
    $outputs[$o.Name] = [ordered]@{
        type  = $o.Value.type
        value = "[reference('$NestedDeploymentName').outputs.$($o.Name).value]"
    }
}
$outputs['_wrapperInfo'] = [ordered]@{
    type  = 'string'
    value = 'Deployed via thin wrapper -> azuredeploy-full.json. For CLI redeploy use scripts/deploy.ps1.'
}

$wrapper = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata       = [ordered]@{
        _generator = [ordered]@{
            name    = 'klz-thin-wrapper'
            version = '1.0'
            purpose = 'Thin wrapper that forwards parameters to azuredeploy-full.json via ARM templateLink. Keeps the Portal deeplink fetch under the practical ~1MB size limit. See deploy/README.md.'
        }
    }
    parameters     = $src.parameters
    resources      = @(
        [ordered]@{
            type       = 'Microsoft.Resources/deployments'
            apiVersion = '2022-09-01'
            name       = $NestedDeploymentName
            location   = "[parameters('location')]"
            properties = [ordered]@{
                mode         = 'Incremental'
                templateLink = [ordered]@{
                    uri            = $FullTemplateRawUri
                    contentVersion = '1.0.0.0'
                }
                parameters   = $forwarded
            }
        }
    )
    outputs        = $outputs
}

$wrapper | ConvertTo-Json -Depth 100 | Set-Content $wrapPath -Encoding utf8 -NoNewline

$wrapSize = (Get-Item $wrapPath).Length
$fullSize = (Get-Item $fullPath).Length
$paramCount  = @($wrapper.parameters.PSObject.Properties).Count
$outputCount = @($wrapper.outputs.PSObject.Properties).Count

Write-Host ""
Write-Host "Wrapper regenerated:" -ForegroundColor Green
Write-Host ("  azuredeploy.json (wrapper) : {0:N0} bytes ({1:N1} KB)" -f $wrapSize, ($wrapSize / 1KB))
Write-Host ("  azuredeploy-full.json      : {0:N0} bytes ({1:N2} MB)" -f $fullSize, ($fullSize / 1MB))
Write-Host ("  Forwarded parameters       : $paramCount")
Write-Host ("  Passthrough outputs        : $outputCount")
Write-Host ("  Full template URI in wrapper:")
Write-Host ("    $FullTemplateRawUri")
Write-Host ""
Write-Host "Next: git add deploy/ && git commit && git push" -ForegroundColor Yellow
