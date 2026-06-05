# rbac/ — Standalone RBAC assignments

`assignments.bicep` is intentionally **standalone** (not wired into `infra/bicep/main.bicep`). It exists so:

1. App teams that bring their own runtime managed identity can grant least-priv access **after** `main.bicep` has deployed the platform.
2. RBAC re-grants can be reapplied without disturbing infra deploys (idempotent by `guid()` name derivation).
3. The deploy can target the **Foundry RG scope**, which is required for `Microsoft.Authorization/roleAssignments` against Cognitive Services (avoids `BCP036` at sub scope).

## What it grants

| Identity | Target | Role |
|---|---|---|
| `apimPrincipalId` (optional) | Foundry account | Cognitive Services OpenAI User |
| `appRuntimePrincipalId` (optional) | Foundry account | Cognitive Services User |
| `appRuntimePrincipalId` (optional) | AI Search | Search Index Data Reader |
| `appRuntimePrincipalId` + `agentAuditDcrId` (both required) | Agent-audit DCR | Monitoring Metrics Publisher |

All four assignments are conditional — pass only the principals you have, the others no-op.

> The live APIM→Foundry grant is already done by `infra/bicep/modules/ai-gateway/apim-foundry-rbac.bicep` inside main.bicep. This module is the backup pattern for out-of-band re-runs or for granting **additional** app-runtime identities.

## Deploy

Source the outputs from the last `main.bicep` run, then deploy to the **Foundry RG**:

```powershell
$out = Get-Content out-full-dev.json | ConvertFrom-Json
$foundryRg = ($out.foundryAccountId.value -split '/')[4]

# Example: grant a new app-runtime managed identity
az deployment group create `
  --resource-group $foundryRg `
  --template-file rbac/assignments.bicep `
  --parameters `
    foundryAccountId=$($out.foundryAccountId.value) `
    searchServiceId=$($out.searchServiceId.value) `
    appRuntimePrincipalId=<your-app-mi-object-id> `
    agentAuditDcrId=$($out.agentAuditDcrId.value)
```

For a dry run, add `--what-if` or use the matching `assignments.json` file with `az deployment group what-if`.

## Re-runs

The module derives assignment names via `guid(scope, principalId, roleSlug)`. Re-running with the same inputs is a no-op. Changing the principal ID creates a new assignment (the old one must be deleted manually).

## Permissions to deploy

Caller needs `Microsoft.Authorization/roleAssignments/write` at the target RG scope. That typically maps to **Owner** or **User Access Administrator** on the RG.
