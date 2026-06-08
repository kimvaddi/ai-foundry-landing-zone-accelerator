###############################################################################
# finops — DCE + custom LAW tables + 3 DCRs for FinOps telemetry
#
# Mirrors infra/bicep/modules/finops/custom-tables.bicep EXACTLY (table names,
# column lists, retention, DCR splits) because finops/chargeback/monthly-
# showback.kql joins these tables by name:
#
#   • PRICING_CL            — 6 cols, 90-day retention
#   • SUBSCRIPTION_QUOTA_CL — 6 cols, 365-day retention
#   • KlzAgentAudit_CL      — 25 cols, 365-day retention
#
# BREAKING for any TF state that still references the old TF-only names
# (AgentAudit_CL, PricingSnapshot_CL, QuotaSnapshot_CL): you must
# `terraform state rm module.finops.azapi_resource.custom_table[<old>]` and
# the corresponding old DCR before `terraform apply`. No production TF
# tenants exist pre-GA so this is acceptable.
###############################################################################

variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "workspace_resource_id" { type = string }
variable "workspace_name" {
  type        = string
  description = "LAW workspace name — used to name the DCE + DCRs (matches Bicep dce-$${workspaceName} pattern)."
}
variable "tags" {
  type    = map(string)
  default = {}
}

# Schema source of truth — matches Bicep custom-tables.bicep column lists.
locals {
  pricing_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "Model", type = "string" },
    { name = "Region", type = "string" },
    { name = "InputPricePer1KTokens", type = "real" },
    { name = "OutputPricePer1KTokens", type = "real" },
    { name = "Currency", type = "string" },
  ]

  quota_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "SubscriptionId", type = "string" },
    { name = "ProjectName", type = "string" },
    { name = "CostCenter", type = "string" },
    { name = "MonthlyQuotaUsd", type = "real" },
    { name = "AlertThresholdPct", type = "int" },
  ]

  agent_audit_columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "CorrelationId", type = "string" },
    { name = "ProjectName", type = "string" },
    { name = "UseCase", type = "string" },
    { name = "CostCenter", type = "string" },
    { name = "SubscriptionId", type = "string" },
    { name = "PolicyTemplate", type = "string" },
    { name = "PolicyVersion", type = "string" },
    { name = "Decision", type = "string" },
    { name = "Signal", type = "string" },
    { name = "ViolatedPolicy", type = "string" },
    { name = "ViolatedField", type = "string" },
    { name = "Reason", type = "string" },
    { name = "Model", type = "string" },
    { name = "OperationId", type = "string" },
    { name = "PromptTokens", type = "int" },
    { name = "CompletionTokens", type = "int" },
    { name = "TotalTokens", type = "int" },
    { name = "EstimatedCostUsd", type = "real" },
    { name = "LatencyMs", type = "int" },
    { name = "HttpStatus", type = "int" },
    { name = "GatewayHost", type = "string" },
    { name = "Region", type = "string" },
    { name = "AgentName", type = "string" },
    { name = "AgentVersion", type = "string" },
    { name = "AuditPayload", type = "dynamic" },
  ]

  tables = {
    "PRICING_CL" = {
      columns         = local.pricing_columns
      retention_days  = 90
      stream_name     = "Custom-PRICING_CL"
      dcr_name_prefix = "dcr-pricing"
    }
    "SUBSCRIPTION_QUOTA_CL" = {
      columns         = local.quota_columns
      retention_days  = 365
      stream_name     = "Custom-SUBSCRIPTION_QUOTA_CL"
      dcr_name_prefix = "dcr-quota"
    }
    "KlzAgentAudit_CL" = {
      columns         = local.agent_audit_columns
      retention_days  = 365
      stream_name     = "Custom-KlzAgentAudit_CL"
      dcr_name_prefix = "dcr-agent-audit"
    }
  }
}

# Data Collection Endpoint — name matches Bicep dce-${workspaceName} so that
# parity-diff (which compares {Type, Count}) sees the same DCE node.
resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                = "dce-${var.workspace_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Custom tables — direct azapi resources because azurerm has incomplete coverage
# for custom LAW tables (no `plan` field, no per-table retention).
resource "azapi_resource" "custom_table" {
  for_each  = local.tables
  type      = "Microsoft.OperationalInsights/workspaces/tables@2023-09-01"
  name      = each.key
  parent_id = var.workspace_resource_id

  schema_validation_enabled = false

  body = {
    properties = {
      schema = {
        name    = each.key
        columns = each.value.columns
      }
      retentionInDays = each.value.retention_days
      plan            = "Analytics"
    }
  }
}

# 3 DCRs — one per table (mirrors Bicep). Splitting keeps each DCR small,
# matches the Bicep parity shape, and lets RBAC scopes target a single
# stream (e.g. agent-runtime gets MonitoringMetricsPublisher only on the
# audit DCR).
resource "azapi_resource" "dcr" {
  for_each = local.tables

  type      = "Microsoft.Insights/dataCollectionRules@2023-03-11"
  name      = "${each.value.dcr_name_prefix}-${var.workspace_name}"
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location
  tags      = var.tags

  schema_validation_enabled = false

  body = {
    kind = "Direct"
    properties = {
      dataCollectionEndpointId = azurerm_monitor_data_collection_endpoint.this.id
      streamDeclarations = {
        (each.value.stream_name) = {
          columns = each.value.columns
        }
      }
      destinations = {
        logAnalytics = [{
          name                = "law"
          workspaceResourceId = var.workspace_resource_id
        }]
      }
      dataFlows = [{
        streams      = [each.value.stream_name]
        destinations = ["law"]
        outputStream = each.value.stream_name
      }]
    }
  }

  response_export_values = ["properties.immutableId"]

  depends_on = [azapi_resource.custom_table]
}

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Outputs (match Bicep custom-tables.bicep)
# -----------------------------------------------------------------------------
output "dce_id" { value = azurerm_monitor_data_collection_endpoint.this.id }
output "dce_ingestion_endpoint" { value = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint }
output "dce_endpoint" { value = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint }

output "pricing_dcr_id" { value = azapi_resource.dcr["PRICING_CL"].id }
output "pricing_dcr_immutable_id" { value = azapi_resource.dcr["PRICING_CL"].output.properties.immutableId }

output "quota_dcr_id" { value = azapi_resource.dcr["SUBSCRIPTION_QUOTA_CL"].id }
output "quota_dcr_immutable_id" { value = azapi_resource.dcr["SUBSCRIPTION_QUOTA_CL"].output.properties.immutableId }

output "agent_audit_dcr_id" { value = azapi_resource.dcr["KlzAgentAudit_CL"].id }
output "agent_audit_dcr_immutable_id" { value = azapi_resource.dcr["KlzAgentAudit_CL"].output.properties.immutableId }
output "agent_audit_stream" { value = local.tables["KlzAgentAudit_CL"].stream_name }

output "custom_table_names" { value = keys(local.tables) }
