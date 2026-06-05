# Phase C stakeholders (D4)

> **Status:** staged with **made-up Contoso-style placeholders** so the artifacts
> ship complete and reviewable. the customer replaces every `*@contoso.example` address
> with a real owner/group before any policy or DLP rule is enabled.

## Decision (D4, 2026-05-25)

Use **option C — placeholder pattern** (matches D3 approach). Staging defaults
shipped in the repo:

| Role | Staging email (placeholder) | Owns | Applied to |
|---|---|---|---|
| **IAM Owner** | `iam-team@contoso.example` | Entra ID, Conditional Access, app registrations | All `governance/shadow-ai/ca-policies/*.json` |
| **SecOps Owner** | `secops@contoso.example` | Defender for Cloud Apps (MCAS), Defender for AI | `governance/shadow-ai/mcas-connectors.md`, alert routing |
| **Compliance Owner** | `compliance@contoso.example` | Purview DLP, audit, info protection | All `governance/shadow-ai/purview-dlp/*.json`, audit DCR |

## Fill these in before any policy is enabled

```text
IAM_OWNER_EMAIL              = iam-team@contoso.example
IAM_APPROVER_GROUP_OBJECT_ID = <fill: Entra group object id of IAM approvers>

SECOPS_OWNER_EMAIL           = secops@contoso.example
SECOPS_ONCALL_PAGERDUTY_KEY  = <fill: integration key for Defender for AI alerts>

COMPLIANCE_OWNER_EMAIL       = compliance@contoso.example
COMPLIANCE_APPROVER_GROUP_OBJECT_ID = <fill: Entra group object id of compliance approvers>
```

## Search-and-replace token map (run before any deploy)

These tokens appear in the Phase C artifacts as `_REPLACE_WITH_*_` strings.
Use a single PowerShell pass to swap them:

```powershell
$tokens = @{
  '_REPLACE_WITH_IAM_OWNER_EMAIL_'         = $IAM_OWNER_EMAIL
  '_REPLACE_WITH_IAM_APPROVER_GROUP_ID_'   = $IAM_APPROVER_GROUP_OBJECT_ID
  '_REPLACE_WITH_SECOPS_OWNER_EMAIL_'      = $SECOPS_OWNER_EMAIL
  '_REPLACE_WITH_COMPLIANCE_OWNER_EMAIL_'  = $COMPLIANCE_OWNER_EMAIL
  '_REPLACE_WITH_COMPLIANCE_APPROVER_ID_'  = $COMPLIANCE_APPROVER_GROUP_OBJECT_ID
  # App / group GUIDs that already shipped as placeholders in ca-policies/*.json:
  '_REPLACE_WITH_OPENAI_APP_ID_'                       = '<openai-app-objectid>'
  '_REPLACE_WITH_ANTHROPIC_APP_ID_'                    = '<anthropic-app-objectid>'
  '_REPLACE_WITH_GEMINI_APP_ID_'                       = '<gemini-app-objectid>'
  '_REPLACE_WITH_SANCTIONED_M365_COPILOT_APP_ID_'      = '<m365-copilot-app-id>'
  '_REPLACE_WITH_SANCTIONED_FOUNDRY_PROJECT_APP_ID_'   = '<foundry-app-id>'
  '_REPLACE_WITH_AI_RESEARCH_GROUP_OBJECT_ID_'         = '<ai-research-group-id>'
}

Get-ChildItem governance/shadow-ai -Recurse -Include *.json,*.md |
  ForEach-Object {
    $c = Get-Content -Raw $_.FullName
    foreach ($k in $tokens.Keys) { $c = $c.Replace($k, $tokens[$k]) }
    Set-Content -Path $_.FullName -Value $c -NoNewline
  }
```

## Sign-off ladder

Phase C artifacts NEVER deploy automatically. The ladder is:

1. **Build (us)** — JSONs ship with placeholders, no behaviour.
2. **the customer** runs the token-swap script above against a copy of the repo for his
   tenant, fills in real owners.
3. **CA policy → IAM Owner approval** → import via `New-MgIdentityConditionalAccessPolicy`
   in `state: enabledForReportingButNotEnforced` (already the default).
4. **MCAS connector → SecOps Owner approval** → enable via portal per
   `mcas-connectors.md`.
5. **Purview DLP → Compliance Owner approval** → import via Purview Graph
   in `mode: TestWithoutNotifications` (already the default).
6. **Flip from report-only / simulation to enforce** only after each owner
   signs off independently. None of those flips are automated by us.
