###############################################################################
# foundation — LAW + App Insights + Key Vault (always deployed)
#
# Bicep parity (closes pre-workshop dual-stack gap):
#  * App Insights uses azapi to set CustomMetricsOptedInType=WithDimensions
#    (silent FinOps bug fix — azurerm provider does not surface this) and
#    DisableLocalAuth=true (PSRule Azure.AppInsights.LocalAuth).
#  * Key Vault: purge protection + default-deny network ACLs + template
#    deployment enabled + audit/allLogs/AllMetrics diag setting to LAW.
#  * Optional KV private endpoint (deployed when pe_subnet_id is supplied).
#
# IRREVERSIBLE: KV purge protection cannot be disabled once on. The vault
# will auto-purge after the 7-day retention window after destroy — costs
# nothing while soft-deleted.
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "resource_group_id" {
  type        = string
  description = "Parent RG resource ID — needed by azapi for App Insights direct resource."
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "pe_subnet_id" {
  type        = string
  default     = null
  description = "Optional Private Endpoint subnet ID. When supplied (along with kv_private_dns_zone_id), a Key Vault PE is created."
}

variable "kv_private_dns_zone_id" {
  type        = string
  default     = null
  description = "Optional privatelink.vaultcore.azure.net zone ID. Required when pe_subnet_id is set."
}

# -----------------------------------------------------------------------------
# Log Analytics workspace
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# App Insights — workspace-based; direct azapi resource because the azurerm
# provider does not expose CustomMetricsOptedInType, and without it APIM
# azure-openai-emit-token-metric DROPS the 6 chargeback dimensions on
# ingestion. See infra/bicep/modules/foundation/app-insights.bicep for the
# Bicep mirror with the same #disable-next-line BCP037 rationale.
# -----------------------------------------------------------------------------
resource "azapi_resource" "app_insights" {
  type      = "Microsoft.Insights/components@2020-02-02"
  name      = "appi-${var.base_name}"
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  schema_validation_enabled = false

  body = {
    kind = "web"
    properties = {
      Application_Type                = "web"
      WorkspaceResourceId             = azurerm_log_analytics_workspace.this.id
      IngestionMode                   = "LogAnalytics"
      publicNetworkAccessForIngestion = "Enabled"
      publicNetworkAccessForQuery     = "Enabled"
      DisableIpMasking                = false
      # Required for multi-dimensional APIM emit-token-metric.
      CustomMetricsOptedInType = "WithDimensions"
      # Force Entra-only auth (PSRule Azure.AppInsights.LocalAuth).
      DisableLocalAuth = true
    }
  }

  response_export_values = [
    "id",
    "properties.ConnectionString",
    "properties.InstrumentationKey",
  ]
}

# -----------------------------------------------------------------------------
# Key Vault — standard SKU, RBAC, purge protection, default-deny network ACLs,
# template deployment enabled (sibling modules pull secrets at deploy time).
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                            = substr("kv-${replace(var.base_name, "-", "")}", 0, 24)
  location                        = var.location
  resource_group_name             = var.resource_group_name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  sku_name                        = "standard"
  rbac_authorization_enabled      = true
  purge_protection_enabled        = true
  soft_delete_retention_days      = 7
  enabled_for_template_deployment = true
  public_network_access_enabled   = true
  tags                            = var.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

# Key Vault diagnostic setting -> LAW (audit + allLogs categoryGroups, AllMetrics).
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "send-to-law"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "audit"
  }
  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Optional Key Vault private endpoint (parity with Bicep main.bicep peKeyVault).
resource "azurerm_private_endpoint" "kv" {
  count               = var.pe_subnet_id != null && var.kv_private_dns_zone_id != null ? 1 : 0
  name                = "pe-kv-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.kv_private_dns_zone_id]
  }
}

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "workspace_resource_id" { value = azurerm_log_analytics_workspace.this.id }
output "workspace_name" { value = azurerm_log_analytics_workspace.this.name }
output "workspace_customer_id" { value = azurerm_log_analytics_workspace.this.workspace_id }

output "app_insights_id" { value = azapi_resource.app_insights.id }
output "app_insights_name" { value = azapi_resource.app_insights.name }
output "app_insights_connection_string" {
  value     = azapi_resource.app_insights.output.properties.ConnectionString
  sensitive = true
}
output "app_insights_instrumentation_key" {
  value     = azapi_resource.app_insights.output.properties.InstrumentationKey
  sensitive = true
}

output "key_vault_id" { value = azurerm_key_vault.this.id }
output "key_vault_uri" { value = azurerm_key_vault.this.vault_uri }
output "key_vault_name" { value = azurerm_key_vault.this.name }
output "key_vault_pe_id" { value = length(azurerm_private_endpoint.kv) > 0 ? azurerm_private_endpoint.kv[0].id : null }
