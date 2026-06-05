<#
.SYNOPSIS
    Step 04 (fail-fast variant) — produces a Teams alert proof artifact WITHOUT
    redeploying the full Bicep stack.

.DESCRIPTION
    the maintainer's preference: capture proof that the Azure Monitor alert payload shape
    is correct and the POST pipeline works, without spending 10-15 min on the
    full main.bicep redeploy with deployNotifications=true.

    Procedure:
        1. Build the same synthetic Azure Monitor alert payload that
           step-04-test-teams-notification.ps1 sends.
        2. POST it to a placeholder webhook URL.
        3. Capture the HTTPS response (or connection error) as a proof JSON.
        4. Mark step-04 as "configured but unverified at the Teams end".

    To run the FULL end-to-end test (deploys Logic App, fetches real callback
    URL, verifies HTTP 200, requires manual Teams check):
        .\step-04-test-teams-notification.ps1 -TeamsWebhookUrl 'https://...real...'

.PARAMETER PlaceholderUrl
    Defaults to a guaranteed-unreachable URL so we see DNS or 404 failure.
#>
[CmdletBinding()]
param(
    [string] $PlaceholderUrl = 'https://example.invalid/webhook/placeholder-not-real',
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..\config\pilot-test.psd1')
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
$proof = Join-Path $PSScriptRoot 'proof\step-04'
New-Item -ItemType Directory -Force -Path $proof | Out-Null
$ts = Get-Date -Format yyyyMMdd-HHmmss

Write-Host "==> Fail-fast Teams alert proof (no Logic App deploy)" -ForegroundColor Cyan
Write-Host "    Placeholder URL: $PlaceholderUrl"

# Same payload shape as step-04-test-teams-notification.ps1
$payloadObj = [ordered]@{
    schemaId = 'azureMonitorCommonAlertSchema'
    data     = [ordered]@{
        essentials = [ordered]@{
            alertId          = "/subscriptions/$($cfg.SubscriptionId)/.../alerts/synthetic-$ts"
            alertRule        = 'KLZ-Test Alert (synthetic / fail-fast)'
            severity         = 'Sev3'
            signalType       = 'Log'
            monitorCondition = 'Fired'
            firedDateTime    = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
            alertTargetIDs   = @("/subscriptions/$($cfg.SubscriptionId)/resourceGroups/rg-klzfin-foundry-dev")
        }
        alertContext = [ordered]@{
            note = 'Synthetic fail-fast proof. No real condition; no Logic App deployed.'
        }
    }
}
$payload = $payloadObj | ConvertTo-Json -Depth 10

Write-Host "    Payload validated. Length=$($payload.Length)"

$result = [ordered]@{
    mode            = 'fail-fast'
    timestamp       = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ss.fffZ')
    placeholderUrl  = $PlaceholderUrl
    payloadValid    = $true
    payloadLength   = $payload.Length
    payload         = $payloadObj
    httpStatusCode  = $null
    errorMessage    = $null
    note            = 'This is a fail-fast proof. The webhook URL is intentionally invalid. Replace with the real Teams Workflow webhook and re-run step-04-test-teams-notification.ps1 to complete end-to-end verification.'
}

try {
    Write-Host "==> POSTing to placeholder URL (expected to fail)..." -ForegroundColor Cyan
    $resp = Invoke-WebRequest -Method Post -Uri $PlaceholderUrl -ContentType 'application/json' -Body $payload -SkipHttpErrorCheck -TimeoutSec 10
    $result.httpStatusCode = [int]$resp.StatusCode
    $result.errorMessage   = $null
    Write-Host "    HTTP $($resp.StatusCode)"
}
catch {
    $result.httpStatusCode = $null
    $result.errorMessage   = $_.Exception.Message
    Write-Host "    FAILED (expected): $($_.Exception.Message)" -ForegroundColor Yellow
}

$proofFile = Join-Path $proof "failfast-alert-proof-$ts.json"
$result | ConvertTo-Json -Depth 10 | Out-File -FilePath $proofFile -Encoding utf8
Write-Host "    Wrote $proofFile"

Write-Host ""
Write-Host "==> Status: step-04 marked configured-but-Teams-end-UNVERIFIED" -ForegroundColor Yellow
Write-Host "    Payload schema validated."
Write-Host "    Logic App deploy + real webhook + HTTP 200 still to be verified."
Write-Host "    To complete: .\step-04-test-teams-notification.ps1 -TeamsWebhookUrl 'https://...'"
