// Application Insights — workspace-based, sends to LAW.
//
// Direct Microsoft.Insights/components (not AVM) because we must set
// `CustomMetricsOptedInType: 'WithDimensions'` — without this opt-in,
// the dimensions on `azure-openai-emit-token-metric` (apim-policies/
// inbound-emit-metrics.xml: ProjectName, UseCase, CostCenter, etc.) are
// silently dropped at ingestion. AVM insights/component:0.7.1 does not
// surface this property today.
//
// Same resource name as before, so this is an in-place property update on
// re-deploy, not a recreate.
param name string
param location string
param workspaceResourceId string
param tags object = {}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceResourceId
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableIpMasking: false
    // Required for multi-dimensional custom metrics emitted from APIM
    // `azure-openai-emit-token-metric` to surface dimensions in Metrics
    // Explorer + workbook KQL. Without this, dimensions are dropped at
    // ingestion and the cost-attribution dashboard shows null project /
    // cost-center. The Bicep type definition lags the platform schema
    // here — ARM accepts the property; disable the strict-type lint.
    #disable-next-line BCP037
    CustomMetricsOptedInType: 'WithDimensions'
    // Force Entra-only auth (closes PSRule Azure.AppInsights.LocalAuth).
    // App Insights local API-key auth is deprecated and adds an exfil path;
    // managed identities should be used for all SDK access instead.
    DisableLocalAuth: true
  }
}

output resourceId string = appi.id
output connectionString string = appi.properties.ConnectionString
output instrumentationKey string = appi.properties.InstrumentationKey
