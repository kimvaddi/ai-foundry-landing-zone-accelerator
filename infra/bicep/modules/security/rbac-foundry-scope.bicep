// =====================================================================
// rbac-foundry-scope.bicep — Post-deploy RBAC assignments at the
// Foundry resource group scope.
//
// Implements Microsoft's recommended Foundry RBAC model:
//   https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry
//
// Built-in role GUIDs are used (not display names) so the module is
// rename-safe (the 2025 Foundry-role rename keeps GUIDs stable).
//
// Each role assignment is gated by an `empty()` check on its target
// principal, so callers can wire only the principals they care about.
// =====================================================================

@description('Foundry Cognitive Services account name (in this RG).')
param foundryAccountName string

@description('Optional: AI Search service name (in this RG). When empty, Search role grant is skipped.')
param searchServiceName string = ''

@description('Entra group object ID that receives Foundry Owner on the Foundry account. Empty to skip.')
param foundryAdminGroupObjectId string = ''

@description('Entra group object ID that receives Foundry Project Manager on the Foundry account. Empty to skip.')
param foundryLeadGroupObjectId string = ''

@description('Entra group object ID that receives Foundry User on the Foundry account. Empty to skip.')
param foundryDeveloperGroupObjectId string = ''

@description('Entra group object ID that receives Reader on the Foundry account. Empty to skip.')
param foundryReaderGroupObjectId string = ''

@description('Foundry account system-assigned MI principal ID. Empty to skip Search role grant.')
param foundryAccountPrincipalId string = ''

@description('Array of Foundry project system-assigned MI principal IDs. Each gets Foundry User on the account and (when Search is present) Search Index Data Reader. Microsoft guidance: project MIs are the runtime identity for BYOR connections, so they need these grants — not the account MI.')
param projectPrincipalIds array = []

// --- Microsoft Foundry built-in role definition GUIDs (rename-safe) ---
// Source: https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry
var roleFoundryOwner          = 'c883944f-8b7b-4483-af10-35834be79c4a'
var roleFoundryProjectManager = 'eadc314b-1a2d-4efa-be10-5d325db5065e'
var roleFoundryUser           = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var roleReader                = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var roleSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'

// ---------------------------------------------------------------------
// Existing resource refs
// ---------------------------------------------------------------------

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (!empty(searchServiceName)) {
  name: searchServiceName
}

// ---------------------------------------------------------------------
// Human group role assignments on the Foundry account
// ---------------------------------------------------------------------

resource raFoundryOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryAdminGroupObjectId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, foundryAdminGroupObjectId, roleFoundryOwner)
  properties: {
    principalId: foundryAdminGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryOwner)
    description: 'Foundry Owner for admin group (klz-accelerator post-deploy RBAC).'
  }
}

resource raFoundryLead 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryLeadGroupObjectId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, foundryLeadGroupObjectId, roleFoundryProjectManager)
  properties: {
    principalId: foundryLeadGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryProjectManager)
    description: 'Foundry Project Manager for team-lead group (klz-accelerator post-deploy RBAC).'
  }
}

resource raFoundryDev 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryDeveloperGroupObjectId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, foundryDeveloperGroupObjectId, roleFoundryUser)
  properties: {
    principalId: foundryDeveloperGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryUser)
    description: 'Foundry User for developer group (klz-accelerator post-deploy RBAC).'
  }
}

resource raFoundryReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryReaderGroupObjectId)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, foundryReaderGroupObjectId, roleReader)
  properties: {
    principalId: foundryReaderGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleReader)
    description: 'Reader for auditor/SRE group (klz-accelerator post-deploy RBAC).'
  }
}

// ---------------------------------------------------------------------
// Foundry account MI -> Search (account-level fallback / safety net)
// Most workloads use the project MI (see below). Keeping this as well
// is harmless and covers any account-scoped runtime that may emerge.
// ---------------------------------------------------------------------

resource raFoundryToSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(searchServiceName) && !empty(foundryAccountPrincipalId)) {
  scope: searchService
  name: guid(searchService.id, foundryAccountPrincipalId, roleSearchIndexDataReader)
  properties: {
    principalId: foundryAccountPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    description: 'Foundry account MI -> Search Index Data Reader (klz-accelerator post-deploy RBAC).'
  }
}

// ---------------------------------------------------------------------
// Project MIs -> Foundry User on the Foundry account
// Microsoft's RBAC doc: project managed identities need Foundry User on
// the parent account to operate. Without this, agent runs and BYOR data
// operations fail with 403 from inside the project context.
// ---------------------------------------------------------------------

resource raProjectFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in projectPrincipalIds: if (!empty(pid)) {
  scope: foundryAccount
  name: guid(foundryAccount.id, pid, roleFoundryUser, 'project')
  properties: {
    principalId: pid
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleFoundryUser)
    description: 'Project MI -> Foundry User on parent account (klz-accelerator post-deploy RBAC).'
  }
}]

// ---------------------------------------------------------------------
// Project MIs -> Search Index Data Reader on AI Search
// BYOR Search connections execute under the project MI, not the account
// MI. This grant unblocks grounding / index queries from project agents.
// NOTE: This is READ-ONLY. For workflows that create or update Search
// indexes from a project, manually grant `Search Index Data Contributor`
// (8ebe5a00-799e-43f5-93ac-243d3dce84a7) or `Search Service Contributor`
// (7ca78c08-252a-4471-8644-bb5ff32d4ba0) on top of this assignment.
// ---------------------------------------------------------------------

resource raProjectToSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (pid, i) in projectPrincipalIds: if (!empty(searchServiceName) && !empty(pid)) {
  scope: searchService
  name: guid(searchService.id, pid, roleSearchIndexDataReader, 'project')
  properties: {
    principalId: pid
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataReader)
    description: 'Project MI -> Search Index Data Reader (klz-accelerator post-deploy RBAC).'
  }
}]

// ---------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------

output assignedFoundryOwner          bool = !empty(foundryAdminGroupObjectId)
output assignedFoundryProjectManager bool = !empty(foundryLeadGroupObjectId)
output assignedFoundryUser           bool = !empty(foundryDeveloperGroupObjectId)
output assignedFoundryReader         bool = !empty(foundryReaderGroupObjectId)
output assignedFoundryToSearch       bool = !empty(searchServiceName) && !empty(foundryAccountPrincipalId)
output assignedProjectMIs            int  = length(projectPrincipalIds)
