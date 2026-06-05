// APIM AI Gateway — Product, API, Backend, Policy attachment.
//
// Loads the inbound metrics policy (apim-policies/inbound-emit-metrics.xml)
// at service scope, and the product token-limit policy at product scope.
// Adds a single AI API pointing at the Foundry openai endpoint, secured by
// MI (no key passthrough).

@description('APIM service name (parent).')
param apimName string

@description('Foundry account endpoint (https://aif-<suffix>.cognitiveservices.azure.com).')
param foundryEndpoint string

@description('Foundry resource id — used for the backend resource-id property (enables MI auth).')
param foundryResourceId string

@description('Resource id of the APIM `applicationinsights` logger (output of apim.bicep). Required for the applicationinsights diagnostic that drives the azure-openai-emit-token-metric policy + per-request telemetry into App Insights.')
param appInsightsLoggerId string

@description('Per-product TPM cap. Templated into product-token-limit.xml.')
param productTokensPerMinute int = 50000

@description('Enable Azure AI Content Safety category scoring (Hate/Sexual/Violence/SelfHarm). Adds llm-content-safety policy element + content-safety-backend.')
param enableContentSafety bool = false

@description('Enable Prompt Shields jailbreak / indirect-injection detection. Reuses the same llm-content-safety element and content-safety-backend as enableContentSafety. If either is true, the element is added; shield-prompt attribute reflects this flag.')
param enablePromptShields bool = false

@description('Content Safety severity threshold (FourSeverityLevels: 0/2/4/6). 4 = block medium+ severity (default).')
@allowed([ 0, 2, 4, 6 ])
param safetyThreshold int = 4

@description('Content Safety endpoint. Defaults to Foundry account endpoint (kind=AIServices exposes /contentsafety/* on the same FQDN).')
param contentSafetyEndpoint string = foundryEndpoint

@description('Content Safety resource id — used for backend resourceId (enables MI auth). Defaults to Foundry resource id.')
param contentSafetyResourceId string = foundryResourceId

@description('Enable APIM semantic cache (vector-similarity prompt match). Requires Redis Enterprise with RediSearch + an embedding deployment.')
param enableSemanticCache bool = false

@description('Embedding deployment name used by the semantic cache lookup policy.')
param embeddingsDeploymentName string = 'text-embedding-3-large'

// ---------------- Validation ----------------
// (External cache is provisioned by apim-redis-cache.bicep when
// enableSemanticCache=true — see main.bicep for the wiring.)

// ---------------- Parent service reference ----------------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// ---------------- Service-scope inbound policy ----------------
resource servicePolicy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../../../apim-policies/inbound-emit-metrics.xml')
  }
}

// ---------------- Backend pointing at Foundry openai sub-endpoint ----------------
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-openai'
  properties: {
    description: 'Microsoft Foundry / Azure OpenAI'
    url: '${foundryEndpoint}openai'
    protocol: 'http'
    resourceId: '${environment().resourceManager}${substring(foundryResourceId, 1)}'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    circuitBreaker: {
      rules: [
        {
          name: 'foundry-429-breaker'
          failureCondition: {
            count: 5
            errorReasons: [ 'Server errors' ]
            interval: 'PT1M'
            statusCodeRanges: [ { min: 429, max: 429 } ]
          }
          tripDuration: 'PT30S'
        }
      ]
    }
  }
}

// ---------------- Backend: Content Safety (conditional) ----------------
// Per Microsoft docs (llm-content-safety policy reference) and the official
// Azure-Samples/AI-Gateway/labs/content-safety/main.bicep sample, the backend
// MUST configure credentials.managedIdentity.resource = "https://cognitiveservices.azure.com"
// for the <llm-content-safety> policy to authenticate to /contentsafety/text:*.
// Without this credentials block, APIM forwards UNAUTHENTICATED requests and the
// backend returns 401 — surfaced to the caller as 403 ContentBlocked for ALL prompts
// (including benign), which we hit in the 2026-06-05 validation. APIM MI also needs
// "Cognitive Services User" role on the CS account (granted in apim-foundry-rbac.bicep
// for Foundry-bundled CS; required separately for a standalone CS resource).
resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = if (enableContentSafety || enablePromptShields) {
  parent: apim
  name: 'content-safety-backend'
  properties: {
    description: 'Azure AI Content Safety (Foundry-bundled or standalone)'
    // The <llm-content-safety> policy adds its own /contentsafety/text:* paths.
    // Trim trailing slash to avoid double-slash, do NOT add /contentsafety here.
    url: replace(contentSafetyEndpoint, '/contentsafety', '') // tolerate either-style param
    protocol: 'http'
    resourceId: '${environment().resourceManager}${substring(contentSafetyResourceId, 1)}'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// ---------------- Backend: Embeddings (conditional) ----------------
resource embeddingsBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = if (enableSemanticCache) {
  parent: apim
  name: 'embeddings-backend'
  properties: {
    description: 'Foundry embeddings deployment for APIM semantic cache.'
    url: '${foundryEndpoint}openai'
    protocol: 'http'
    resourceId: '${environment().resourceManager}${substring(foundryResourceId, 1)}'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// ---------------- Named value: embeddings deployment (conditional) ----
resource embeddingsDeploymentNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = if (enableSemanticCache) {
  parent: apim
  name: 'azure-openai-embeddings-deployment-name'
  properties: {
    displayName: 'azure-openai-embeddings-deployment-name'
    value: embeddingsDeploymentName
    secret: false
  }
}

// ---------------- External cache: provisioned by apim-redis-cache.bicep --
// (Resource creation lives in a sibling module to satisfy BCP426; see main.bicep.)

// ---------------- AI API (OpenAI-compatible surface) ----------------
resource aiApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'foundry-openai'
  properties: {
    displayName: 'Foundry OpenAI'
    description: 'AI Gateway exposing Foundry models via MI-backed proxy.'
    path: 'openai'
    protocols: [ 'https' ]
    subscriptionRequired: true
    type: 'http'
    serviceUrl: '${foundryEndpoint}openai'
    apiType: 'http'
  }
}

// Minimal POST operation: /deployments/{deployment-id}/chat/completions
resource chatCompletionsOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: aiApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deployment-id}/chat/completions'
    templateParameters: [
      {
        name: 'deployment-id'
        required: true
        type: 'string'
      }
    ]
    request: {
      queryParameters: [
        { name: 'api-version', required: true, type: 'string', defaultValue: '2024-10-21' }
      ]
    }
  }
}

// ---------------- API-level policy (assembled) ----------------
// Loads the assembly template + replaces the 3 placeholders with fragment
// XML (or empty string) based on the safety/cache toggles. Always-on bits
// (backend selection + MI auth) live in the template.
var _csFragment = (enableContentSafety || enablePromptShields)
  ? replace(replace(loadTextContent('../../../../apim-policies/fragments/llm-content-safety.inbound.xml'), '__SHIELD_PROMPT__', enablePromptShields ? 'true' : 'false'), '__SAFETY_THRESHOLD__', string(safetyThreshold))
  : ''
var _scInbound = enableSemanticCache ? loadTextContent('../../../../apim-policies/fragments/semantic-cache.inbound.xml') : ''
var _scOutbound = enableSemanticCache ? loadTextContent('../../../../apim-policies/fragments/semantic-cache.outbound.xml') : ''
var _apiPolicy = replace(replace(replace(loadTextContent('../../../../apim-policies/fragments/api-policy.xml.tpl'), '__CONTENT_SAFETY_INBOUND__', _csFragment), '__SEMANTIC_CACHE_INBOUND__', _scInbound), '__SEMANTIC_CACHE_OUTBOUND__', _scOutbound)

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: aiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: _apiPolicy
  }
  dependsOn: [
    foundryBackend
    contentSafetyBackend
    embeddingsBackend
  ]
}

// ---------------- Product with token-limit policy ----------------
resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'foundry-default'
  properties: {
    displayName: 'Foundry Default'
    description: 'Default product for AI Gateway consumption (TPM cap parameterised).'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: product
  name: aiApi.name
}

resource productPolicy 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = {
  parent: product
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('../../../../apim-policies/product-token-limit.xml'), '__TOKENS_PER_MINUTE__', string(productTokensPerMinute))
  }
  dependsOn: [
    productApiLink
  ]
}

// ---------------- LAW diagnostic: capture cost-attribution headers ----
//
// Pumps `x-project` / `x-use-case` / `x-cost-center` into
// `ApiManagementGatewayLogs.RequestHeaders` so the finops cost KQL can
// fall back to header-based attribution when an APIM product subscription
// has no row in SUBSCRIPTION_QUOTA_CL.
//
// `loggerId` references the IMPLICIT logger named `azuremonitor` that
// APIM auto-creates the moment `Microsoft.Insights/diagnosticSettings`
// is wired to a Log Analytics workspace (AVM `api-management/service`
// does this via the `diagnosticSettings` param in apim.bicep). The
// logger is not a Bicep resource we declare — but `resourceId()` is
// safe to use because the platform guarantees it exists by the time
// this child resource is processed (module dep on `apim.outputs.name`).
//
// Resource name MUST be `azuremonitor` (case-sensitive) for the settings
// to flow into LAW's `ApiManagementGatewayLogs` schema.
resource apimAzMonDiag 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: resourceId('Microsoft.ApiManagement/service/loggers', apim.name, 'azuremonitor')
    alwaysLog: 'allErrors'
    // NOTE: httpCorrelationProtocol is App Insights-only and is rejected
    // by ARM for the `azuremonitor` diagnostic. Do not re-add.
    verbosity: 'information'
    logClientIp: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [
          'x-project'
          'x-use-case'
          'x-cost-center'
          'User-Agent'
        ]
      }
      response: {
        headers: []
      }
    }
    backend: {
      request: {
        headers: []
      }
      response: {
        headers: [
          'x-ms-region'
        ]
      }
    }
  }
}

// ---------------- App Insights diagnostic --------------------------
//
// The COMPANION to apimAzMonDiag. Two distinct things at play:
//   - `azuremonitor` diagnostic (above)      -> shape of LAW gateway-log
//                                               records (header capture
//                                               for the chargeback KQL).
//   - `applicationinsights` diagnostic (here) -> per-request telemetry
//                                               into App Insights AND
//                                               unlocks `azure-openai-
//                                               emit-token-metric` so
//                                               the policy actually
//                                               emits custom metrics.
//
// Without this resource the emit-token-metric policy in
// apim-policies/inbound-emit-metrics.xml is a silent no-op — App
// Insights `customMetrics` stays empty even though the policy XML
// declares the dimensions.
//
// `httpCorrelationProtocol: W3C` IS valid here (and only here — ARM
// rejects it on the `azuremonitor` diagnostic). Enables end-to-end
// trace correlation in App Insights Application Map.
resource apimAppiDiag 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: appInsightsLoggerId
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [
          'x-project'
          'x-use-case'
          'x-cost-center'
        ]
      }
      response: {
        headers: []
      }
    }
    backend: {
      request: {
        headers: []
      }
      response: {
        headers: [
          'x-ms-region'
        ]
      }
    }
  }
}

output productName string = product.name
output apiName string = aiApi.name
