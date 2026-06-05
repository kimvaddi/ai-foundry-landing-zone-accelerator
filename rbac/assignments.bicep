// rbac/assignments.bicep — wires service-principal MIs to least-priv roles.
//
// Run AFTER main.bicep so output IDs are available. Designed for re-run safety.

@description('Foundry account resource ID (output of main.bicep).')
param foundryAccountId string

@description('AI Search resource ID (output of main.bicep).')
param searchServiceId string

@description('AAD object ID of the APIM managed identity, if APIM is deployed.')
param apimPrincipalId string = ''

@description('AAD object ID of an app/runtime managed identity that needs to call Foundry.')
param appRuntimePrincipalId string = ''

@description('Resource ID of the agent-audit DCR (output of finops module). Required if appRuntimePrincipalId is set; grants Monitoring Metrics Publisher so the runtime client can ingest into KlzAgentAudit_CL.')
param agentAuditDcrId string = ''

// ----------------- role definition GUIDs (do not change) ----------------
var cogServicesUserRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
)
var cogServicesOpenAiUserRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
)
var searchIndexDataReader = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
)
var monitoringMetricsPublisher = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher
)

// ----------------- APIM → Foundry (data plane, OpenAI) ------------------
// Note: the live APIM→Foundry grant is done by infra/bicep/modules/ai-gateway/
// apim-foundry-rbac.bicep (scoped to rgFoundry) — this is a backup pattern for
// out-of-band RBAC re-runs. To avoid BCP036 in subscription-mode deployments,
// the assignment is created at the deployment scope; deploy this module to
// the RG that owns the foundry account.
resource apimToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  name: guid(foundryAccountId, apimPrincipalId, 'cogsvc-openai-user')
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cogServicesOpenAiUserRole
  }
}

// ----------------- App runtime → Foundry (data plane) -------------------
resource appToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(appRuntimePrincipalId)) {
  name: guid(foundryAccountId, appRuntimePrincipalId, 'cogsvc-user')
  properties: {
    principalId: appRuntimePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cogServicesUserRole
  }
}

// ----------------- App runtime → AI Search (read) -----------------------
resource appToSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(appRuntimePrincipalId)) {
  name: guid(searchServiceId, appRuntimePrincipalId, 'search-data-reader')
  properties: {
    principalId: appRuntimePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchIndexDataReader
  }
}

// ----------------- App runtime → KlzAgentAudit_CL DCR (Phase B.3) -------
// Monitoring Metrics Publisher on the DCR scope = "may POST to the DCR's
// logsIngestion endpoint for the streams it declares". Strictly write-only;
// does NOT grant read on LAW. Required for the runtime client to write
// audit rows.
resource appToAuditDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(appRuntimePrincipalId) && !empty(agentAuditDcrId)) {
  name: guid(agentAuditDcrId, appRuntimePrincipalId, 'monitoring-metrics-publisher')
  properties: {
    principalId: appRuntimePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringMetricsPublisher
  }
}

output assignmentCount int = (empty(apimPrincipalId) ? 0 : 1) + (empty(appRuntimePrincipalId) ? 0 : 2) + ((!empty(appRuntimePrincipalId) && !empty(agentAuditDcrId)) ? 1 : 0)
