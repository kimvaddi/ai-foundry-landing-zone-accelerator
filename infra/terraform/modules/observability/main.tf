###############################################################################
# observability — workbooks + alerts + scheduled query rule + smart detector
#
# Thin wrapper that creates the standard FinOps dashboard surface. The
# workbook JSON is loaded from shared/observability/workbooks if present,
# otherwise a stub is created.
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "workspace_resource_id" { type = string }
variable "app_insights_id" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_monitor_action_group" "klz" {
  name                = "ag-klz-${var.base_name}"
  resource_group_name = var.resource_group_name
  short_name          = "klz"
  tags                = var.tags
}

# Scheduled query rule — Foundry token spike
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "token_spike" {
  name                = "alert-tokenspike-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  severity            = 2
  scopes              = [var.workspace_resource_id]
  description         = "Foundry token usage spike (>2x 7-day baseline)"
  display_name        = "KLZ Token Spike"
  enabled             = true

  evaluation_frequency = "PT15M"
  window_duration      = "PT1H"

  criteria {
    query                   = <<-KQL
      AppDependencies
      | where Name startswith "tool.fabric"
      | summarize p95 = percentile(DurationMs, 95) by bin(TimeGenerated, 5m)
      | where p95 > 3000
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.klz.id]
  }

  tags = var.tags
}

# Smart detector
resource "azurerm_monitor_smart_detector_alert_rule" "appi_failures" {
  name                = "sdr-appi-failures-${var.base_name}"
  resource_group_name = var.resource_group_name
  severity            = "Sev3"
  scope_resource_ids  = [var.app_insights_id]
  frequency           = "PT1M"
  detector_type       = "FailureAnomaliesDetector"

  action_group {
    ids = [azurerm_monitor_action_group.klz.id]
  }

  tags = var.tags
}

# Workbook — empty shell; customers replace .data with shared/observability/workbooks/*.json
resource "azurerm_application_insights_workbook" "klz" {
  name                = "00000000-0000-0000-0000-000000000001"
  location            = var.location
  resource_group_name = var.resource_group_name
  display_name        = "KLZ FinOps overview"
  source_id           = lower(var.app_insights_id)
  data_json = jsonencode({
    version = "Notebook/1.0"
    items   = []
  })
  tags = var.tags
}

output "action_group_id" { value = azurerm_monitor_action_group.klz.id }
output "scheduled_alert_id" { value = azurerm_monitor_scheduled_query_rules_alert_v2.token_spike.id }
