// =============================================================================
// KLZ FinOps Accelerator — Logic App notification stub (Phase B.4)
// =============================================================================
// SAFETY: This module is disabled-by-default. It creates a Logic App in the
// 'Disabled' state with empty webhook/email parameters. To activate, set
// `enabled = true` AND populate destinations, then re-deploy. This module
// MUST NOT auto-fire alerts in any environment without an operator turning
// it on intentionally.
//
// Purpose: route Action Group webhooks (from observability/alerts.bicep) into
// a workflow that can fan out to Teams, ServiceNow, PagerDuty, email, etc.
// =============================================================================

@description('Resource name of the Logic App.')
param name string

@description('Region; usually inherited from the parent deployment.')
param location string

@description('Common tags.')
param tags object = {}

@description('Master switch. Leave false until destinations are configured AND change has been approved.')
param enabled bool = false

@description('Optional Teams Incoming Webhook URL. Stored as a workflow parameter, empty by default.')
@secure()
param teamsWebhookUrl string = ''

@description('Optional ServiceNow ingestion endpoint. Stored as a workflow parameter, empty by default.')
@secure()
param serviceNowEndpoint string = ''

@description('Optional comma-separated email list for fallback notifications. Empty by default.')
param notificationEmails string = ''

@description('Connection ID for the office365 connector if email is enabled. Empty by default. Reserved — wired into a `triggers/email` action in a future iteration.')
#disable-next-line no-unused-params
param office365ConnectionId string = ''

// -----------------------------------------------------------------------------
// Logic App workflow
// -----------------------------------------------------------------------------
resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: union(tags, {
    'klz:component': 'notifications'
    'klz:state': enabled ? 'enabled' : 'disabled'
  })
  properties: {
    // KEY SAFETY GATE — Disabled until operator flips `enabled`.
    state: enabled ? 'Enabled' : 'Disabled'
    parameters: {
      '$connections': {
        value: {}
      }
      teamsWebhookUrl: {
        value: teamsWebhookUrl
      }
      serviceNowEndpoint: {
        value: serviceNowEndpoint
      }
      notificationEmails: {
        value: notificationEmails
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
          defaultValue: {}
        }
        teamsWebhookUrl: {
          type: 'SecureString'
          defaultValue: ''
        }
        serviceNowEndpoint: {
          type: 'SecureString'
          defaultValue: ''
        }
        notificationEmails: {
          type: 'String'
          defaultValue: ''
        }
      }
      triggers: {
        // Receives Azure Monitor Action Group webhook payloads.
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                schemaId: { type: 'string' }
                data: {
                  type: 'object'
                  properties: {
                    essentials: {
                      type: 'object'
                      properties: {
                        alertId: { type: 'string' }
                        alertRule: { type: 'string' }
                        severity: { type: 'string' }
                        signalType: { type: 'string' }
                        monitorCondition: { type: 'string' }
                        firedDateTime: { type: 'string' }
                      }
                    }
                    alertContext: { type: 'object' }
                  }
                }
              }
            }
          }
        }
      }
      actions: {
        // ---------------------------------------------------------------
        // Branch 1: Post to Teams when teamsWebhookUrl is non-empty.
        // Works with both classic Incoming Webhook (MessageCard) and
        // the modern Power Automate "Workflows" Incoming Webhook
        // (Adaptive Card). We send the Adaptive Card shape because
        // Workflows is the only path Microsoft is actively supporting
        // post-Oct-2024.
        // ---------------------------------------------------------------
        Check_Teams_Webhook: {
          type: 'If'
          runAfter: {}
          expression: {
            and: [
              {
                not: {
                  equals: [
                    '@parameters(\'teamsWebhookUrl\')'
                    ''
                  ]
                }
              }
            ]
          }
          actions: {
            Post_to_Teams: {
              type: 'Http'
              runAfter: {}
              inputs: {
                method: 'POST'
                uri: '@parameters(\'teamsWebhookUrl\')'
                headers: {
                  'Content-Type': 'application/json'
                }
                body: {
                  type: 'message'
                  attachments: [
                    {
                      contentType: 'application/vnd.microsoft.card.adaptive'
                      content: {
                        '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json'
                        type: 'AdaptiveCard'
                        version: '1.5'
                        body: [
                          {
                            type: 'TextBlock'
                            size: 'Large'
                            weight: 'Bolder'
                            color: 'Attention'
                            text: '@{concat(\'KLZ Alert: \', coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertRule\'], \'unknown rule\'))}'
                            wrap: true
                          }
                          {
                            type: 'FactSet'
                            facts: [
                              {
                                title: 'Severity'
                                value: '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'severity\'], \'n/a\')}'
                              }
                              {
                                title: 'Condition'
                                value: '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'monitorCondition\'], \'n/a\')}'
                              }
                              {
                                title: 'Signal'
                                value: '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'signalType\'], \'n/a\')}'
                              }
                              {
                                title: 'Fired'
                                value: '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'firedDateTime\'], \'n/a\')}'
                              }
                              {
                                title: 'AlertId'
                                value: '@{coalesce(triggerBody()?[\'data\']?[\'essentials\']?[\'alertId\'], \'n/a\')}'
                              }
                            ]
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
          else: {
            actions: {}
          }
        }
        // ---------------------------------------------------------------
        // Branch 2: Always-on 200 response so Azure Monitor Action Group
        // marks the webhook delivery as success even if the Teams branch
        // is skipped or fails.
        // ---------------------------------------------------------------
        Respond_200: {
          type: 'Response'
          runAfter: {
            Check_Teams_Webhook: [
              'Succeeded'
              'Failed'
              'Skipped'
              'TimedOut'
            ]
          }
          inputs: {
            statusCode: 200
            body: {
              status: 'accepted'
              teamsPosted: '@{if(equals(actions(\'Check_Teams_Webhook\')?[\'status\'], \'Succeeded\'), \'true\', \'false\')}'
            }
          }
        }
      }
      outputs: {}
    }
  }
}

output workflowId string = workflow.id
output workflowState string = enabled ? 'Enabled' : 'Disabled'
output triggerCallbackHint string = 'After enabling, fetch the manual trigger URL via: az rest --method post --uri "${workflow.id}/triggers/manual/listCallbackUrl?api-version=2019-05-01"'
