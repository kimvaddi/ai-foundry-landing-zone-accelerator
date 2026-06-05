# Auto-suspend (over-quota response)

When a project breaches its `MonthlyQuotaUsd`, the scheduled query rule
`sqr-cost-vs-quota-*` fires. The action group routes to a Logic App that
calls APIM Management API to set the APIM subscription state to `suspended`.

## Logic App contract

| Step | Method | URL | Notes |
|------|--------|-----|-------|
| 1 | POST | `https://management.azure.com/{apimSubId}?api-version=2024-05-01` | Body: `{ "properties": { "state": "suspended", "stateComment": "Auto-suspended by FinOps alert" } }` |
| 2 | POST | `https://graph.microsoft.com/v1.0/users/{owner}/sendMail` | Optional: notify project owner |

## Why not deploy this in smoke mode

The Logic App needs an APIM subscription resource ID — which only exists in
`mode=full`. Smoke mode skips APIM. The Logic App + Workflow definition will
ship in a later iteration (`infra/bicep/modules/finops/auto-suspend.bicep`)
behind a feature flag.

## Manual unblock procedure (during PoC)

```powershell
$apimSubId = "/subscriptions/.../resourceGroups/.../providers/Microsoft.ApiManagement/service/<apim>/subscriptions/<sub>"
az rest --method PATCH `
  --uri "$apimSubId?api-version=2024-05-01" `
  --body '{ "properties": { "state": "active" } }'
```
