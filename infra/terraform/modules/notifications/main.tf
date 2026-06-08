###############################################################################
# notifications — Logic App workflow that receives Action Group webhooks and
# fans out to Teams / ServiceNow / Email.
#
# Mirrors infra/bicep/modules/observability/notifications.bicep 1:1. SAFETY:
# the workflow is created in the Disabled state by default. Set enabled = true
# AND populate destinations to activate. Never auto-fires alerts.
#
# Workflow definition lives in ./workflow-definition.json so the HCL stays
# readable. The file ships unchanged from the Bicep definition; if you edit
# one, edit the other (parity is enforced by scripts/parity-diff.ps1).
###############################################################################

variable "name" {
  type        = string
  description = "Logic App workflow name (e.g. logic-notif-<basename>)."
}

variable "location" { type = string }
variable "resource_group_name" { type = string }

variable "enabled" {
  type        = bool
  default     = false
  description = "Master switch. Leave false until destinations are configured AND the change has been approved. Workflow state is Disabled when false."
}

variable "teams_webhook_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional Teams Incoming Webhook URL. Stored as a SecureString workflow parameter."
}

variable "service_now_endpoint" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional ServiceNow ingestion endpoint."
}

variable "notification_emails" {
  type        = string
  default     = ""
  description = "Optional comma-separated email list for fallback notifications (reserved for future activation)."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  state_tag = var.enabled ? "enabled" : "disabled"
  state     = var.enabled ? "Enabled" : "Disabled"

  workflow_definition = jsondecode(file("${path.module}/workflow-definition.json"))
}

resource "azurerm_logic_app_workflow" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  enabled             = var.enabled

  workflow_parameters = {
    "$connections"     = jsonencode({ type = "Object", defaultValue = {} })
    teamsWebhookUrl    = jsonencode({ type = "SecureString", defaultValue = "" })
    serviceNowEndpoint = jsonencode({ type = "SecureString", defaultValue = "" })
    notificationEmails = jsonencode({ type = "String", defaultValue = "" })
  }

  parameters = {
    "$connections"     = jsonencode({})
    teamsWebhookUrl    = var.teams_webhook_url
    serviceNowEndpoint = var.service_now_endpoint
    notificationEmails = var.notification_emails
  }

  tags = merge(var.tags, {
    "klz:component" = "notifications"
    "klz:state"     = local.state_tag
  })
}

# Trigger + actions live as child resources because azurerm_logic_app_workflow
# only accepts top-level `parameters`/`workflow_parameters`. The trigger/action
# JSON is sourced verbatim from workflow-definition.json for Bicep parity.
resource "azurerm_logic_app_trigger_http_request" "manual" {
  name         = "manual"
  logic_app_id = azurerm_logic_app_workflow.this.id
  schema       = jsonencode(local.workflow_definition.triggers.manual.inputs.schema)
}

resource "azurerm_logic_app_action_custom" "check_teams_webhook" {
  name         = "Check_Teams_Webhook"
  logic_app_id = azurerm_logic_app_workflow.this.id
  body         = jsonencode(local.workflow_definition.actions.Check_Teams_Webhook)

  depends_on = [azurerm_logic_app_trigger_http_request.manual]
}

resource "azurerm_logic_app_action_custom" "respond_200" {
  name         = "Respond_200"
  logic_app_id = azurerm_logic_app_workflow.this.id
  body         = jsonencode(local.workflow_definition.actions.Respond_200)

  depends_on = [azurerm_logic_app_action_custom.check_teams_webhook]
}

output "workflow_id" { value = azurerm_logic_app_workflow.this.id }
output "workflow_name" { value = azurerm_logic_app_workflow.this.name }
output "workflow_state" { value = local.state }
output "trigger_callback_hint" {
  value = "After enabling, fetch the manual trigger URL via: az rest --method post --uri \"${azurerm_logic_app_workflow.this.id}/triggers/manual/listCallbackUrl?api-version=2019-05-01\""
}
