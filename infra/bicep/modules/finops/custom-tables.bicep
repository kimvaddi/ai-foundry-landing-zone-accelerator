// Custom Log Analytics tables for FinOps + DCRs.
//
// PRICING_CL            — price per 1K input/output tokens, per model+region.
// SUBSCRIPTION_QUOTA_CL — monthly $ quota per APIM subscription / project.
// KlzAgentAudit_CL      — Phase B.3: per-call audit events from the
//                         agent-runtime governance enforcement client.
//                         One row per agent call, allowed or denied, with
//                         policy_template, decision, signal, latency,
//                         and the full chargeback dimension set.
//
// Each table gets a Data Collection Endpoint (DCE) + Data Collection Rule (DCR)
// so prices/quotas/audits can be POSTed from a CI job, the runtime client,
// or a maintenance pipeline without granting workspace-keys.

@description('Existing Log Analytics workspace name (in the same RG).')
param workspaceName string

@description('Existing Log Analytics workspace resource ID.')
param workspaceResourceId string

@description('Location.')
param location string

@description('Tags.')
param tags object = {}

// ---------------------- Workspace child ref ------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// ---------------------- Custom tables ------------------------------------
resource pricingTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'PRICING_CL'
  properties: {
    schema: {
      name: 'PRICING_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'Model', type: 'string' }
        { name: 'Region', type: 'string' }
        { name: 'InputPricePer1KTokens', type: 'real' }
        { name: 'OutputPricePer1KTokens', type: 'real' }
        { name: 'Currency', type: 'string' }
      ]
    }
    retentionInDays: 90
    plan: 'Analytics'
  }
}

resource quotaTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'SUBSCRIPTION_QUOTA_CL'
  properties: {
    schema: {
      name: 'SUBSCRIPTION_QUOTA_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'SubscriptionId', type: 'string' }
        { name: 'ProjectName', type: 'string' }
        { name: 'CostCenter', type: 'string' }
        { name: 'MonthlyQuotaUsd', type: 'real' }
        { name: 'AlertThresholdPct', type: 'int' }
      ]
    }
    retentionInDays: 365
    plan: 'Analytics'
  }
}

// ---------------------- KlzAgentAudit_CL (Phase B.3) ---------------------
// One row per agent call. Populated by governance/agent-runtime/runtime/
// klz_client.py on every decision (allowed AND denied). Composed policy
// (klz-baseline / klz-production) writes here via the audit.destinations
// = log_analytics block; the runtime client posts to the DCR endpoint with
// a Monitoring Metrics Publisher role grant (see rbac/assignments.bicep).
resource agentAuditTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: law
  name: 'KlzAgentAudit_CL'
  properties: {
    schema: {
      name: 'KlzAgentAudit_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        // request identity / chargeback
        { name: 'CorrelationId', type: 'string' }
        { name: 'ProjectName', type: 'string' }
        { name: 'UseCase', type: 'string' }
        { name: 'CostCenter', type: 'string' }
        { name: 'SubscriptionId', type: 'string' }
        // policy decision
        { name: 'PolicyTemplate', type: 'string' }       // klz-baseline | klz-production
        { name: 'PolicyVersion', type: 'string' }
        { name: 'Decision', type: 'string' }             // allow | deny
        { name: 'Signal', type: 'string' }               // SIGCONT | SIGSTOP | SIGKILL
        { name: 'ViolatedPolicy', type: 'string' }       // first failing policy name, or ''
        { name: 'ViolatedField', type: 'string' }        // category | rule | header
        { name: 'Reason', type: 'string' }
        // call details
        { name: 'Model', type: 'string' }
        { name: 'OperationId', type: 'string' }          // chat-completions | embeddings | ...
        { name: 'PromptTokens', type: 'int' }
        { name: 'CompletionTokens', type: 'int' }
        { name: 'TotalTokens', type: 'int' }
        { name: 'EstimatedCostUsd', type: 'real' }
        { name: 'LatencyMs', type: 'int' }
        { name: 'HttpStatus', type: 'int' }
        // call environment
        { name: 'GatewayHost', type: 'string' }
        { name: 'Region', type: 'string' }
        { name: 'AgentName', type: 'string' }
        { name: 'AgentVersion', type: 'string' }
        // free-form payload for forensics (small JSON, opt-in only)
        { name: 'AuditPayload', type: 'dynamic' }
      ]
    }
    retentionInDays: 365
    plan: 'Analytics'
  }
}

// ---------------------- Data Collection Endpoint -------------------------
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-${workspaceName}'
  location: location
  tags: tags
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

// ---------------------- DCRs (Direct ingestion) --------------------------
resource pricingDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-pricing-${workspaceName}'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-PRICING_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Model', type: 'string' }
          { name: 'Region', type: 'string' }
          { name: 'InputPricePer1KTokens', type: 'real' }
          { name: 'OutputPricePer1KTokens', type: 'real' }
          { name: 'Currency', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        { name: 'law', workspaceResourceId: workspaceResourceId }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-PRICING_CL' ]
        destinations: [ 'law' ]
        outputStream: 'Custom-PRICING_CL'
      }
    ]
  }
  dependsOn: [ pricingTable ]
}

resource quotaDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-quota-${workspaceName}'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-SUBSCRIPTION_QUOTA_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'SubscriptionId', type: 'string' }
          { name: 'ProjectName', type: 'string' }
          { name: 'CostCenter', type: 'string' }
          { name: 'MonthlyQuotaUsd', type: 'real' }
          { name: 'AlertThresholdPct', type: 'int' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        { name: 'law', workspaceResourceId: workspaceResourceId }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-SUBSCRIPTION_QUOTA_CL' ]
        destinations: [ 'law' ]
        outputStream: 'Custom-SUBSCRIPTION_QUOTA_CL'
      }
    ]
  }
  dependsOn: [ quotaTable ]
}

// ---------------------- agent-audit DCR (Phase B.3) ----------------------
// Stream name MUST match Custom-<TableName>_CL convention; outputStream
// drops back to Custom-<TableName> per LAW direct-ingest schema.
resource agentAuditDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-agent-audit-${workspaceName}'
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-KlzAgentAudit_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'CorrelationId', type: 'string' }
          { name: 'ProjectName', type: 'string' }
          { name: 'UseCase', type: 'string' }
          { name: 'CostCenter', type: 'string' }
          { name: 'SubscriptionId', type: 'string' }
          { name: 'PolicyTemplate', type: 'string' }
          { name: 'PolicyVersion', type: 'string' }
          { name: 'Decision', type: 'string' }
          { name: 'Signal', type: 'string' }
          { name: 'ViolatedPolicy', type: 'string' }
          { name: 'ViolatedField', type: 'string' }
          { name: 'Reason', type: 'string' }
          { name: 'Model', type: 'string' }
          { name: 'OperationId', type: 'string' }
          { name: 'PromptTokens', type: 'int' }
          { name: 'CompletionTokens', type: 'int' }
          { name: 'TotalTokens', type: 'int' }
          { name: 'EstimatedCostUsd', type: 'real' }
          { name: 'LatencyMs', type: 'int' }
          { name: 'HttpStatus', type: 'int' }
          { name: 'GatewayHost', type: 'string' }
          { name: 'Region', type: 'string' }
          { name: 'AgentName', type: 'string' }
          { name: 'AgentVersion', type: 'string' }
          { name: 'AuditPayload', type: 'dynamic' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        { name: 'law', workspaceResourceId: workspaceResourceId }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-KlzAgentAudit_CL' ]
        destinations: [ 'law' ]
        outputStream: 'Custom-KlzAgentAudit_CL'
      }
    ]
  }
  dependsOn: [ agentAuditTable ]
}

output dceEndpoint string = dce.properties.logsIngestion.endpoint
output pricingDcrImmutableId string = pricingDcr.properties.immutableId
output quotaDcrImmutableId string = quotaDcr.properties.immutableId
output agentAuditDcrImmutableId string = agentAuditDcr.properties.immutableId
output agentAuditDcrId string = agentAuditDcr.id
output agentAuditStream string = 'Custom-KlzAgentAudit_CL'
