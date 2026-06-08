###############################################################################
# observability — workbooks + alerts (mirrors Bicep monitorAlerts + monitorWorkbooks)
#
# Parity with infra/bicep/modules/observability/{alerts.bicep,workbooks.bicep,
# notifications.bicep}:
#   • 2 workbooks: agent-performance + finops-showback (load JSON from repo
#     root observability/workbooks/), source_id = LAW (not App Insights).
#   • Scheduled query alert 1 (always): Fabric tool p95 > 3s.
#   • Scheduled query alert 2 (gated on var.deploy_cost_alert): cost vs quota
#     joining ApiManagementGatewayLlmLog × PRICING_CL × SUBSCRIPTION_QUOTA_CL.
#   • Action group: gated on var.deploy_notifications. When off, alerts fire
#     to the portal only (no email/webhook), matching Bicep's empty() pattern.
#
# Note: smart detector resource removed for parity — Bicep monitorAlerts.bicep
# does not deploy one. App Insights failure detection is built-in in workspace-
# based mode.
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "workspace_resource_id" { type = string }

variable "deploy_notifications" {
  type        = bool
  default     = false
  description = "Deploy the action group (and wire it to alert rules)."
}

variable "deploy_cost_alert" {
  type        = bool
  default     = false
  description = "Deploy the cost-vs-quota scheduled query rule. Requires ApiManagementGatewayLlmLog (APIM deployed + AI Gateway logging enabled)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# Action group (optional)
# -----------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "klz" {
  count               = var.deploy_notifications ? 1 : 0
  name                = "ag-klz-${var.base_name}"
  resource_group_name = var.resource_group_name
  short_name          = "klz"
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Alert 1 — Fabric tool p95 latency > 3s (always)
# -----------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "fabric_p95" {
  name                = "sqr-fabric-p95-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  severity            = 2
  scopes              = [var.workspace_resource_id]
  description         = "Fabric tool span p95 latency exceeds 3 seconds (sustained)."
  display_name        = "KLZ Fabric Tool p95"
  enabled             = true

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"

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

  auto_mitigation_enabled = true

  dynamic "action" {
    for_each = var.deploy_notifications ? [1] : []
    content {
      action_groups = [azurerm_monitor_action_group.klz[0].id]
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Alert 2 — Project cost > 80% of monthly quota (gated)
# -----------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "cost_vs_quota" {
  count               = var.deploy_cost_alert ? 1 : 0
  name                = "sqr-cost-vs-quota-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  severity            = 1
  scopes              = [var.workspace_resource_id]
  description         = "Project MTD cost ≥ 80% of monthly USD quota."
  display_name        = "KLZ Cost vs Quota"
  enabled             = true

  evaluation_frequency = "PT1H"
  window_duration      = "P1D"

  criteria {
    query                   = <<-KQL
      let monthStart = startofmonth(now());
      let prices = PRICING_CL
      | summarize arg_max(TimeGenerated, *) by Model, Region;
      let quotas = SUBSCRIPTION_QUOTA_CL
      | summarize arg_max(TimeGenerated, *) by SubscriptionId, ProjectName;
      union isfuzzy=true ApiManagementGatewayLlmLog
      | where TimeGenerated >= monthStart
      | extend Body = parse_json(tostring(column_ifexists("BackendResponseBody", "")))
      | extend ProjectName = tostring(Body["project"]), SubscriptionId = tostring(Body["subscription_id"])
      | extend ModelName = tostring(column_ifexists("ModelName", ""))
      | extend PromptTokens = tolong(column_ifexists("PromptTokens", 0))
      | extend CompletionTokens = tolong(column_ifexists("CompletionTokens", 0))
      | join kind=leftouter prices on $left.ModelName == $right.Model
      | extend cost = (PromptTokens/1000.0)*InputPricePer1KTokens + (CompletionTokens/1000.0)*OutputPricePer1KTokens
      | summarize MTDCost = sum(cost) by SubscriptionId, ProjectName
      | join kind=leftouter quotas on SubscriptionId, ProjectName
      | extend PctOfQuota = (MTDCost / MonthlyQuotaUsd) * 100
      | where PctOfQuota >= 80
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = false

  dynamic "action" {
    for_each = var.deploy_notifications ? [1] : []
    content {
      action_groups = [azurerm_monitor_action_group.klz[0].id]
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Workbooks — Agent Performance + FinOps Showback
#
# Loaded from repo-root observability/workbooks/. From this module's path
# (infra/terraform/modules/observability/), the repo root is 4 levels up.
# source_id MUST be the LAW resource ID (matches Bicep workbooks.bicep:33,50)
# so queries like AppDependencies / AppExceptions resolve against the
# workspace-based App Insights telemetry.
# -----------------------------------------------------------------------------
locals {
  workbooks = {
    "agent-performance" = {
      display_name = "Foundry — Agent Performance & Tool Latency"
      file_path    = "${path.module}/../../../../observability/workbooks/agent-performance.json"
    }
    "finops-showback" = {
      display_name = "Foundry — FinOps Showback"
      file_path    = "${path.module}/../../../../observability/workbooks/finops-showback.json"
    }
  }
}

resource "azurerm_application_insights_workbook" "klz" {
  for_each            = local.workbooks
  name                = uuidv5("url", "${var.workspace_resource_id}/${each.key}")
  location            = var.location
  resource_group_name = var.resource_group_name
  display_name        = each.value.display_name
  source_id           = lower(var.workspace_resource_id)
  category            = "workbook"
  data_json           = file(each.value.file_path)
  tags                = var.tags
}

output "action_group_id" {
  value = var.deploy_notifications ? azurerm_monitor_action_group.klz[0].id : null
}
output "fabric_alert_id" { value = azurerm_monitor_scheduled_query_rules_alert_v2.fabric_p95.id }
output "cost_alert_id" {
  value = var.deploy_cost_alert ? azurerm_monitor_scheduled_query_rules_alert_v2.cost_vs_quota[0].id : null
}
output "workbook_ids" {
  value = { for k, w in azurerm_application_insights_workbook.klz : k => w.id }
}
