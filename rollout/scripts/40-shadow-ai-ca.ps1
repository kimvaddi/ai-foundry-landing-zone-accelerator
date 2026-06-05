<#
.SYNOPSIS
    Phase C placeholder — Conditional Access policy for shadow-AI controls
    (report-only by default). Not yet implemented; see comments for design.

.DESCRIPTION
    Phase C is intentionally a stub in this iteration. The intended pattern:

      1. Use Graph beta API to POST a CA policy in state=enabledForReportingButNotEnforced
         that scopes 'All cloud apps' or specific Enterprise Apps
         (e.g. 'Microsoft Foundry') and requires compliant device or MFA.
      2. Wait 5-10 minutes for propagation.
      3. Have a test user sign into the targeted app.
      4. Pull /auditLogs/signIns filtered by appDisplayName and verify the
         policy evaluated.
      5. Tear down via DELETE /identity/conditionalAccess/policies/{id}.

    Open questions before code lands:
      - the customer tenant CA admins may already have a baseline.  Need to confirm
        we do not conflict.
      - The DLP / Defender for Cloud Apps piece needs Defender XDR license
        verification (E5 / Microsoft 365 E5 Security).
      - Outbound domain filtering (chat.openai.com etc.) is NOT a CA control;
        it lives in Defender for Cloud Apps 'Unsanctioned apps' or Edge for
        Business managed device policy.  Out of scope for this script.

    For now this script just prints the design so the rollout doesn't appear
    to silently skip Phase C.

.PARAMETER ConfigPath
    Path to customer.psd1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigPath
)
$ErrorActionPreference = 'Stop'

$cfg = Import-PowerShellDataFile -Path $ConfigPath
if (-not $cfg.DeployShadowAiControls) {
    Write-Host "cfg.DeployShadowAiControls = false. Skipping Phase C." -ForegroundColor Yellow
    return
}

Write-Host @"
==> Phase C — Shadow AI controls is STUBBED in this rollout iteration.

Planned scope (next iteration):
  - CA report-only policy targeting Microsoft Foundry enterprise app
  - Defender for Cloud Apps 'Unsanctioned apps' tagging template
  - Optional Edge for Business managed-browser blocklist

Pre-reqs the customer must confirm before this lands:
  - Conditional Access admin role available
  - No conflicting baseline CA policies
  - Defender XDR licensing for shadow-IT visibility

This script intentionally does nothing. Track design in:
  ../docs/PHASE-C-SHADOW-AI-DESIGN.md  (next iteration)
"@ -ForegroundColor Yellow
