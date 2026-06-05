// =============================================================================
// KLZ FinOps Accelerator — OTel collector on Azure Container Apps (Phase B.2)
// =============================================================================
// Receives OTLP traces/metrics from agent runtimes via the in-tree
// observability/otel-genai/python-instrumentation.py wiring and forwards them
// to Azure Monitor (via Application Insights connection string) plus an
// optional second pipeline to a customer-controlled backend.
//
// Scaling defaults are conservative (min 1, max 3, 0.5 vCPU / 1 GiB). Adjust
// after baseline traffic measurement.
//
// REQUIREMENTS:
//   * Container Apps Environment must exist (caller's responsibility).
//   * App Insights connection string from Phase A.
//   * Image must implement the OTel Collector contrib distribution. Default
//     points at the public Microsoft mirror; pin a digest before prod.
// =============================================================================

@description('Container App name.')
param name string

@description('Region; inherited from parent.')
param location string

@description('Resource ID of the Azure Container Apps managed environment.')
param environmentId string

@description('Container image. Pin a digest in prod.')
param image string = 'mcr.microsoft.com/azuremonitor/containerinsights/cidev/applicationinsights-opentelemetry-collector:latest'

@description('App Insights connection string (Phase A output).')
@secure()
param appInsightsConnectionString string

@description('Optional secondary OTLP endpoint (gRPC). Leave empty to skip.')
param secondaryOtlpEndpoint string = ''

@description('CPU cores per replica.')
param cpu string = '0.5'

@description('Memory per replica.')
param memory string = '1Gi'

@description('Minimum replicas.')
@minValue(0)
param minReplicas int = 1

@description('Maximum replicas.')
@minValue(1)
param maxReplicas int = 3

@description('Common tags.')
param tags object = {}

resource collector 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, {
    'klz:component': 'otel-collector'
  })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false                             // internal-only by default
        targetPort: 4317
        transport: 'tcp'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
        additionalPortMappings: [
          {
            external: false
            targetPort: 4318                        // OTLP HTTP
          }
          {
            external: false
            targetPort: 13133                       // health check
          }
        ]
      }
      secrets: [
        {
          name: 'appinsights-connection-string'
          value: appInsightsConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'otel-collector'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              secretRef: 'appinsights-connection-string'
            }
            {
              name: 'KLZ_SECONDARY_OTLP_ENDPOINT'
              value: secondaryOtlpEndpoint
            }
          ]
          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: 13133
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: 13133
              }
              initialDelaySeconds: 5
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'cpu-scale'
            custom: {
              type: 'cpu'
              metadata: {
                type: 'Utilization'
                value: '70'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppId string = collector.id
output principalId string = collector.identity.principalId
output internalFqdn string = collector.properties.configuration.ingress.fqdn
