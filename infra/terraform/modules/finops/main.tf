###############################################################################
# finops — DCE + custom LAW tables for pricing/quota/agent-audit telemetry
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "workspace_resource_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                = "dce-finops-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  kind                = "Linux"
  tags                = var.tags
}

# Custom tables (Pricing, Quota, AgentAudit) — created as azapi resources because
# the azurerm provider's coverage of custom LAW tables is limited.
locals {
  custom_tables = {
    AgentAudit_CL = [
      { name = "TimeGenerated", type = "DateTime" },
      { name = "AgentName", type = "String" },
      { name = "Tool", type = "String" },
      { name = "Outcome", type = "String" },
      { name = "DurationMs", type = "Int" },
      { name = "PromptTokens", type = "Int" },
      { name = "CompletionTokens", type = "Int" },
    ]
    PricingSnapshot_CL = [
      { name = "TimeGenerated", type = "DateTime" },
      { name = "Service", type = "String" },
      { name = "SkuName", type = "String" },
      { name = "Region", type = "String" },
      { name = "UnitPrice", type = "Real" },
      { name = "Currency", type = "String" },
    ]
    QuotaSnapshot_CL = [
      { name = "TimeGenerated", type = "DateTime" },
      { name = "Service", type = "String" },
      { name = "Region", type = "String" },
      { name = "Capability", type = "String" },
      { name = "Limit", type = "Int" },
      { name = "Used", type = "Int" },
    ]
  }
}

resource "azapi_resource" "custom_table" {
  for_each  = local.custom_tables
  type      = "Microsoft.OperationalInsights/workspaces/tables@2023-09-01"
  name      = each.key
  parent_id = var.workspace_resource_id

  body = {
    properties = {
      schema = {
        name    = each.key
        columns = each.value
      }
      retentionInDays      = 30
      totalRetentionInDays = 30
    }
  }
}

# DCR — uses azapi (DCR for custom-table ingestion isn't a clean azurerm resource yet)
resource "azapi_resource" "dcr_finops" {
  type      = "Microsoft.Insights/dataCollectionRules@2023-03-11"
  name      = "dcr-finops-${var.base_name}"
  parent_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  location  = var.location

  body = {
    properties = {
      dataCollectionEndpointId = azurerm_monitor_data_collection_endpoint.this.id
      streamDeclarations = {
        for table_name, columns in local.custom_tables : "Custom-${table_name}" => {
          columns = [
            for c in columns : {
              name = c.name
              type = lookup({
                DateTime = "datetime"
                String   = "string"
                Int      = "int"
                Long     = "long"
                Real     = "real"
                Bool     = "boolean"
                Dynamic  = "dynamic"
              }, c.type, lower(c.type))
            }
          ]
        }
      }
      destinations = {
        logAnalytics = [{
          name                = "law-dest"
          workspaceResourceId = var.workspace_resource_id
        }]
      }
      dataFlows = [
        for table_name, _ in local.custom_tables : {
          streams      = ["Custom-${table_name}"]
          destinations = ["law-dest"]
          outputStream = "Custom-${table_name}"
        }
      ]
    }
  }

  depends_on = [azapi_resource.custom_table]
  tags       = var.tags
}

data "azurerm_client_config" "current" {}

output "dce_id" { value = azurerm_monitor_data_collection_endpoint.this.id }
output "dce_ingestion_endpoint" { value = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint }
output "dcr_id" { value = azapi_resource.dcr_finops.id }
output "custom_table_names" {
  value = keys(local.custom_tables)
}
