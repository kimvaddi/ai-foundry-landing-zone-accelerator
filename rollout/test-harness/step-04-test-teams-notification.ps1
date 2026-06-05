<#
.SYNOPSIS
    Step 04 — proves the notifications Logic App actually posts to Teams.

.DESCRIPTION
    Procedure:
        1. the maintainer creates an Incoming Webhook in a Teams channel (Workflows
           connector preferred; classic Office365 connector also works).
           See https://learn.microsoft.com/microsoftteams/platform/webhooks-and-connectors
        2. the test pilot runs this script with -TeamsWebhookUrl <url>.
        3. Script deploys main.bicep with deployNotifications=true and
           enableNotificationsLogicApp=true, threading the webhook in.
        4. Script fetches the manual trigger URL and POSTs a synthetic
           Azure Monitor alert payload.
        5. Script asserts HTTP 200.
        6. the maintainer manually confirms the card arrived in her Teams channel
           (we cannot verify Teams receipt programmatically without Graph
           Chat.Read.All which is overkill for a smoke test).

    Use -Teardown to redeploy with deployNotifications=false (removes the
    Logic App).

.PARAMETER TeamsWebhookUrl
    The Incoming Webhook URL. Required unless -Teardown.

.PARAMETER ConfigPath
    Defaults to ../config/pilot-test.psd1.

.PARAMETER Teardown
    Redeploy with deployNotifications=false to remove the Logic App.

.EXAMPLE
    .\step-04-test-teams-notification.ps1 -TeamsWebhookUrl 'https://...'
    .\step-04-test-teams-notification.ps1 -Teardown
#>
[CmdletBinding()]
param(
    [string] $TeamsWebhookUrl,
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1'),
    [switch] $Teardown
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$bicep    = Join-Path $repoRoot 'infra\bicep\main.bicep'
$param    = Join-Path $repoRoot 'infra\bicep\parameters\dev.bicepparam'

$proof = Join-Path $PSScriptRoot 'proof\step-04'
New-Item -ItemType Directory -Force -Path $proof | Out-Null
$ts = Get-Date -Format yyyyMMdd-HHmmss

# -----------------------------------------------------------------------------
# Teardown branch
# -----------------------------------------------------------------------------
if ($Teardown) {
    Write-Host "==> Tearing down notifications Logic App..." -ForegroundColor Cyan
    az deployment sub create `
        --name "klz-notif-teardown-$ts" `
        --location $cfg.Location `
        --template-file $bicep `
        --parameters $param `
        --parameters "deployNotifications=false" "enableNotificationsLogicApp=false" "teamsWebhookUrl=" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Teardown deployment failed" }
    Write-Host "Teardown complete." -ForegroundColor Green
    return
}

# -----------------------------------------------------------------------------
# Deploy branch
# -----------------------------------------------------------------------------
if (-not $TeamsWebhookUrl) { throw "TeamsWebhookUrl required (unless -Teardown)." }
if ($TeamsWebhookUrl -notmatch '^https://') { throw "TeamsWebhookUrl must start with https://" }

Write-Host "==> Deploying notifications=true with Teams webhook..." -ForegroundColor Cyan
$deployName = "klz-notif-test-$ts"
az deployment sub create `
    --name $deployName `
    --location $cfg.Location `
    --template-file $bicep `
    --parameters $param `
    --parameters "deployNotifications=true" "enableNotificationsLogicApp=true" "teamsWebhookUrl=$TeamsWebhookUrl" "notificationEmails=" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Notifications deployment failed" }

# -----------------------------------------------------------------------------
# Fetch the trigger callback URL
# -----------------------------------------------------------------------------
$wfId = az deployment sub show --name $deployName --query 'properties.outputs.notificationWorkflowId.value' -o tsv
if (-not $wfId) { throw "notificationWorkflowId output is empty — deployment did not surface workflow id" }
Write-Host "    Workflow id: $wfId"

$cbUri = "${wfId}/triggers/manual/listCallbackUrl?api-version=2019-05-01"
$cb = az rest --method post --uri $cbUri --output json | ConvertFrom-Json
if (-not $cb.value) { throw "listCallbackUrl returned empty" }
Write-Host "    Trigger URL retrieved (length=$($cb.value.Length))"

# -----------------------------------------------------------------------------
# Synthetic Azure Monitor alert payload
# -----------------------------------------------------------------------------
$payload = @{
    schemaId = 'azureMonitorCommonAlertSchema'
    data     = @{
        essentials = @{
            alertId          = "/subscriptions/$($cfg.SubscriptionId)/.../alerts/synthetic-$ts"
            alertRule        = 'KLZ-Test Alert (synthetic)'
            severity         = 'Sev3'
            signalType       = 'Log'
            monitorCondition = 'Fired'
            firedDateTime    = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
            alertTargetIDs   = @("/subscriptions/$($cfg.SubscriptionId)/resourceGroups/rg-klzfin-foundry-dev")
        }
        alertContext = @{
            note = 'This is a synthetic test alert fired by step-04. No real condition was met.'
        }
    }
} | ConvertTo-Json -Depth 10

Write-Host "==> POSTing synthetic alert..." -ForegroundColor Cyan
$resp = Invoke-WebRequest -Method Post -Uri $cb.value -ContentType 'application/json' -Body $payload -SkipHttpErrorCheck
$body = $resp.Content
Write-Host "    HTTP $($resp.StatusCode)"
Write-Host "    Body: $body"

$proofFile = Join-Path $proof "alert-response-$ts.json"
@{
    statusCode = $resp.StatusCode
    body       = $body
    payload    = ($payload | ConvertFrom-Json)
} | ConvertTo-Json -Depth 10 | Out-File -FilePath $proofFile -Encoding utf8
Write-Host "    Wrote $proofFile"

if ($resp.StatusCode -ne 200) {
    Write-Warning "Logic App did not return 200. Inspect run history in portal."
    return
}

Write-Host ""
Write-Host "==> HTTP 200 received. CHECK YOUR TEAMS CHANNEL NOW." -ForegroundColor Green
Write-Host "    Card should show: KLZ Alert: KLZ-Test Alert (synthetic), Sev3."
Write-Host "    If no card arrives within 30 seconds:"
Write-Host "      1. Verify the webhook URL is the FULL Workflows webhook trigger URL"
Write-Host "      2. Check Logic App run history: az logicapp ... OR portal"
Write-Host ""
Write-Host "When done, run: .\step-04-test-teams-notification.ps1 -Teardown" -ForegroundColor Yellow
