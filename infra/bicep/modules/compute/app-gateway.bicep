// =============================================================================
// app-gateway.bicep — Application Gateway v2 + WAF (OWASP 3.2)
//
// Spins up an AppGW WAF_v2 in AppGatewaySubnet with a stub backend pool (caller
// is expected to add real backends post-deploy). Creates its own Standard/Static
// public IP and an attached WAF policy (Prevention mode).
//
// Invariant (per rubber-duck #5): WAF_v2 SKU REQUIRES a WAF policy attachment.
// We enforce this in the template — when sku=WAF_v2, wafEnabled is forced true.
// Set sku=Standard_v2 if you don't want WAF.
// =============================================================================

@description('App Gateway name.')
param name string

@description('Region.')
param location string

@description('Resource ID of AppGatewaySubnet.')
param subnetResourceId string

@description('SKU. WAF_v2 enforces a WAF policy attachment; Standard_v2 has no WAF.')
@allowed([ 'WAF_v2', 'Standard_v2' ])
param skuName string = 'WAF_v2'

@description('Autoscale min capacity.')
param autoscaleMin int = 1

@description('Autoscale max capacity.')
param autoscaleMax int = 3

@description('WAF policy mode. Only honored when skuName=WAF_v2.')
@allowed([ 'Prevention', 'Detection' ])
param wafMode string = 'Prevention'

@description('Diagnostic LAW workspace resource id.')
param workspaceResourceId string

@description('Tags.')
param tags object = {}

var effectiveWaf = skuName == 'WAF_v2'

module pip '../networking/public-ip.bicep' = {
  name: take('pip-appgw-${uniqueString(name)}', 64)
  params: {
    name: 'pip-${name}'
    location: location
    tags: tags
    domainNameLabel: toLower('appgw-${uniqueString(name)}')
  }
}

module wafPolicy 'br/public:avm/res/network/application-gateway-web-application-firewall-policy:0.3.0' = if (effectiveWaf) {
  name: take('waf-${uniqueString(name)}', 64)
  params: {
    name: 'waf-${name}'
    location: location
    tags: tags
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
    policySettings: {
      state: 'Enabled'
      mode: wafMode
      fileUploadLimitInMb: 100
      maxRequestBodySizeInKb: 128
      requestBodyCheck: true
    }
  }
}

resource appgw 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: name
  location: location
  tags: union(tags, { 'klz:component': 'app-gateway' })
  properties: {
    sku: {
      name: skuName
      tier: skuName
    }
    autoscaleConfiguration: {
      minCapacity: autoscaleMin
      maxCapacity: autoscaleMax
    }
    gatewayIPConfigurations: [
      {
        name: 'gw-ipconfig'
        properties: {
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'fe-public'
        properties: {
          publicIPAddress: {
            id: pip.outputs.resourceId
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-default'
        properties: {
          backendAddresses: []
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'http-settings-default'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', name, 'fe-public')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', name, 'port-80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule-default'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', name, 'listener-http')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', name, 'pool-default')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', name, 'http-settings-default')
          }
        }
      }
    ]
    firewallPolicy: effectiveWaf ? {
      id: wafPolicy!.outputs.resourceId
    } : null
  }
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appgw
  name: 'send-to-law'
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output appGatewayId   string = appgw.id
output appGatewayName string = appgw.name
output publicIpId     string = pip.outputs.resourceId
output publicIpFqdn   string = pip.outputs.fqdn
output wafPolicyId    string = effectiveWaf ? wafPolicy!.outputs.resourceId : ''
