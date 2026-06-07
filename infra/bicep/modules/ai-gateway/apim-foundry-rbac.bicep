// RBAC: grant APIM's system-assigned MI the Microsoft-recommended role pair
// on the Foundry account so the APIM AI Gateway can call data-plane endpoints
// (chat completions, embeddings, images, content safety) via MI auth.
//
// Default roles (both granted):
//   - Cognitive Services User              (a97b65f3-24c7-4388-baec-2e87135dc908)
//     Base data-plane access across Cognitive Services kinds (incl. content
//     safety endpoints exposed by the Foundry account kind=AIServices).
//   - Cognitive Services OpenAI User       (5e0bd9bd-7b93-4f28-af87-19fc36ad61bd)
//     REQUIRED for /openai/* (chat/completions/embeddings). Without this the
//     Foundry account returns 401 for /chat/completions even when the SAMI
//     has Cognitive Services User — this is the single most common cause of
//     "APIM 401 from Foundry" runtime failures and is called out in the
//     project memory (RBAC modules that grant only the latter fail at runtime).
//
// Scoped to the Foundry account so the principal cannot reach unrelated
// services. Loop emits one role assignment per role ID with a deterministic
// GUID name keyed by (accountId, principalId, roleId).

@description('Foundry account name (in current scope).')
param foundryAccountName string

@description('Principal id (APIM system-assigned MI).')
param principalId string

@description('Role definition IDs to assign. Defaults follow Microsoft AI Gateway guidance: Cognitive Services User + Cognitive Services OpenAI User. Override only if you know what you are removing.')
param roleDefinitionIds array = [
  'a97b65f3-24c7-4388-baec-2e87135dc908'
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
]

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for rid in roleDefinitionIds: {
  scope: foundryAccount
  name: guid(foundryAccount.id, principalId, rid)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rid)
  }
}]

output roleAssignmentIds array = [for (rid, i) in roleDefinitionIds: ra[i].id]
