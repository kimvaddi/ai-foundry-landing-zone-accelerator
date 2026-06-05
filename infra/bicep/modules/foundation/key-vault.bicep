// Key Vault — Standard SKU, RBAC, soft-delete + purge protection, diag to LAW.
//
// NOTE: per repo memory, KV soft-delete purge is denied in tenants with
// enforced purge protection. The vault will auto-purge after the 7-day
// retention window after teardown — costs nothing while soft-deleted.

@description('Vault name, must be globally unique, 3-24 chars.')
@maxLength(24)
param name string
param location string
param workspaceResourceId string
param tags object = {}

module kv 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: take('kv-${uniqueString(name)}', 64)
  params: {
    name: name
    location: location
    tags: tags
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    // ARM template-deployment KV reads are required by sibling modules that
    // consume secrets at deploy time (e.g., apim-redis-cache pulls the AMR
    // connection string via getSecret()). The deploying principal still
    // needs 'Key Vault Secrets User' on the vault — RBAC is the real gate.
    enableVaultForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      // Default-deny: only Azure trusted services + explicit IP/VNet rules
      // can reach the vault. Closes PSRule Azure.KeyVault.Firewall.
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
    diagnosticSettings: [
      {
        name: 'send-to-law'
        workspaceResourceId: workspaceResourceId
        logCategoriesAndGroups: [ { categoryGroup: 'audit' }, { categoryGroup: 'allLogs' } ]
        metricCategories: [ { category: 'AllMetrics' } ]
      }
    ]
  }
}

output resourceId string = kv.outputs.resourceId
output uri string = kv.outputs.uri
