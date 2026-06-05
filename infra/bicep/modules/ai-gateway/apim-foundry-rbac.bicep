// RBAC: grant APIM's system-assigned MI access to Foundry account.
//
// Role: "Cognitive Services User" (a97b65f3-24c7-4388-baec-2e87135dc908)
// — sufficient for data-plane calls (chat / completions / embeddings) via MI.
// Scoped to the Foundry account so the principal cannot reach unrelated services.

@description('Foundry account name (in current scope).')
param foundryAccountName string

@description('Principal id (APIM system-assigned MI).')
param principalId string

@description('Role definition id (default = Cognitive Services User).')
param roleDefinitionId string = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryAccount
  name: guid(foundryAccount.id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

output roleAssignmentId string = ra.id
