<#
.SYNOPSIS
    Enables Phase B.4 — deploys the notifications Logic App with a real Teams
    webhook URL, then optionally flips its state to Enabled.

.DESCRIPTION
    Wraps infra/bicep/main.bicep redeployment with:
        deployNotifications = true
        teamsWebhookUrl     = <from customer.psd1 OR -TeamsWebhookUrl param>
        enableNotificationsLogicApp = <from cfg.EnableLogicApp>

    The Logic App is created in state='Disabled' UNLESS EnableLogicApp=true.
    Even when disabled, you can still call the HTTP trigger directly for
    testing (the runtime accepts requests; only Action-Group-fired runs need
    the workflow to be Enabled).

.PARAMETER ConfigPath
    Path to customer.psd1.

.PARAMETER TeamsWebhookUrl
    Optional override. If provided, takes precedence over cfg.TeamsWebhookUrl.
    Recommended for testing so the URL is never written to disk.

.PARAMETER WhatIf
    Print the planned deployment without executing.

.EXAMPLE
    .\30-notifications-enable.ps1 -ConfigPath ..\config\customer.psd1 -TeamsWebhookUrl 'https://<tenant>.webhook.office.com/...'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigPath,
    [string] $TeamsWebhookUrl
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath

$webhook = if ($TeamsWebhookUrl) { $TeamsWebhookUrl } else { $cfg.TeamsWebhookUrl }
if (-not $webhook) {
    throw "TeamsWebhookUrl required (pass -TeamsWebhookUrl or set cfg.TeamsWebhookUrl)."
}
if ($webhook -notmatch '^https://') { throw "TeamsWebhookUrl must start with https://" }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$bicep    = Join-Path $repoRoot 'infra\bicep\main.bicep'
$param    = Join-Path $repoRoot 'infra\bicep\parameters\dev.bicepparam'
if (-not (Test-Path $bicep)) { throw "Template not found: $bicep" }

$deployName = "klz-notif-$(Get-Date -Format yyyyMMddHHmm)"
Write-Host "==> Deploying notifications enable to subscription $($cfg.SubscriptionId)..." -ForegroundColor Cyan
Write-Host "    EnableLogicApp = $($cfg.EnableLogicApp)"
Write-Host "    Webhook        = $($webhook.Substring(0,40))..."

# We override only the notification-related params; everything else comes from the bicepparam file.
$inlineParams = @(
    "deployNotifications=true",
    "enableNotificationsLogicApp=$([string]$cfg.EnableLogicApp.ToString().ToLower())",
    "teamsWebhookUrl=$webhook"
)

$args = @(
    'deployment','sub','create',
    '--name', $deployName,
    '--location', $cfg.Location,
    '--template-file', $bicep,
    '--parameters', $param,
    '--parameters'
) + $inlineParams

if (-not $PSCmdlet.ShouldProcess($cfg.SubscriptionId, "Enable notifications Logic App")) {
    Write-Host "    [WhatIf] az $($args -join ' ' -replace [regex]::Escape($webhook), '<webhook>')" -ForegroundColor Cyan
    return
}

az @args
if ($LASTEXITCODE -ne 0) { throw "Deployment failed with exit $LASTEXITCODE" }

Write-Host ""
Write-Host "Done. To get the Logic App callback URL (for Action Group webhook + manual test):" -ForegroundColor Green
Write-Host "  az rest --method post --uri `"/subscriptions/$($cfg.SubscriptionId)/resourceGroups/rg-klzfin-platform-dev/providers/Microsoft.Logic/workflows/<workflow-name>/triggers/manual/listCallbackUrl?api-version=2019-05-01`""
