// =====================================================================
// rbac-platform-scope.bicep — Post-deploy RBAC assignments at the
// platform resource group scope.
//
// Wires up:
//   • Reader on the platform RG for auditor/SRE group
//   • Contributor on the platform RG for the CI/CD deployment SPN
//   • Key Vault Secrets User on the KV for jump + build VM MIs
// =====================================================================

@description('Key Vault name (in this RG). Empty to skip KV role grants.')
param keyVaultName string = ''

@description('Entra group object ID that receives Reader on the platform RG. Empty to skip.')
param platformReaderGroupObjectId string = ''

@description('Service principal object ID that receives Contributor on the platform RG. Empty to skip.')
param deploymentSpnObjectId string = ''

@description('Jump VM system-assigned MI principal ID. Empty to skip KV Secrets User grant.')
param jumpVmPrincipalId string = ''

@description('Build agent VM system-assigned MI principal ID. Empty to skip KV Secrets User grant.')
param buildVmPrincipalId string = ''

// --- Azure built-in role definition GUIDs ---
var roleReader              = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var roleContributor         = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// ---------------------------------------------------------------------
// Existing resource refs
// ---------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = if (!empty(keyVaultName)) {
  name: keyVaultName
}

// ---------------------------------------------------------------------
// RG-scoped human/SPN role assignments
// ---------------------------------------------------------------------

resource raReaderRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(platformReaderGroupObjectId)) {
  scope: resourceGroup()
  name: guid(resourceGroup().id, platformReaderGroupObjectId, roleReader)
  properties: {
    principalId: platformReaderGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleReader)
    description: 'Reader on platform RG (klz-accelerator post-deploy RBAC).'
  }
}

resource raContribRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deploymentSpnObjectId)) {
  scope: resourceGroup()
  name: guid(resourceGroup().id, deploymentSpnObjectId, roleContributor)
  properties: {
    principalId: deploymentSpnObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleContributor)
    description: 'Contributor on platform RG for CI/CD SPN (klz-accelerator post-deploy RBAC).'
  }
}

// ---------------------------------------------------------------------
// Key Vault Secrets User for VM MIs
// ---------------------------------------------------------------------

resource raJumpKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(keyVaultName) && !empty(jumpVmPrincipalId)) {
  scope: keyVault
  name: guid(keyVault.id, jumpVmPrincipalId, roleKeyVaultSecretsUser)
  properties: {
    principalId: jumpVmPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    description: 'Jump VM MI -> Key Vault Secrets User (klz-accelerator post-deploy RBAC).'
  }
}

resource raBuildKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(keyVaultName) && !empty(buildVmPrincipalId)) {
  scope: keyVault
  name: guid(keyVault.id, buildVmPrincipalId, roleKeyVaultSecretsUser)
  properties: {
    principalId: buildVmPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    description: 'Build VM MI -> Key Vault Secrets User (klz-accelerator post-deploy RBAC).'
  }
}

// ---------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------

output assignedReader     bool = !empty(platformReaderGroupObjectId)
output assignedContributor bool = !empty(deploymentSpnObjectId)
output assignedJumpKv     bool = !empty(keyVaultName) && !empty(jumpVmPrincipalId)
output assignedBuildKv    bool = !empty(keyVaultName) && !empty(buildVmPrincipalId)
