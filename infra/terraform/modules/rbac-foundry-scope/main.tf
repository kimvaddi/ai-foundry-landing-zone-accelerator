###############################################################################
# rbac-foundry-scope — Post-deploy RBAC at the Foundry resource group scope.
#
# Mirrors infra/bicep/modules/security/rbac-foundry-scope.bicep exactly.
# Implements Microsoft's Foundry RBAC model:
#   https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry
#
# Uses built-in role definition GUIDs (rename-safe — the 2025 Foundry role
# rename kept GUIDs stable). Each role assignment is gated by an empty/null
# check on its target principal, so partial wiring is valid.
###############################################################################

variable "foundry_account_id" {
  type        = string
  description = "Full resource ID of the Foundry Cognitive Services account."
}

variable "search_service_id" {
  type        = string
  default     = ""
  description = "Full resource ID of the AI Search service. Empty to skip Search role grants."
}

variable "foundry_admin_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry Owner on the Foundry account. Empty to skip."
}

variable "foundry_lead_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry Project Manager. Empty to skip."
}

variable "foundry_developer_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry User. Empty to skip."
}

variable "foundry_reader_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Reader on the Foundry account. Empty to skip."
}

variable "foundry_account_principal_id" {
  type        = string
  default     = ""
  description = "Foundry account system-assigned MI principal ID. Empty to skip Search role grant."
}

variable "project_principal_ids" {
  type        = list(string)
  default     = []
  description = "Foundry project system-assigned MI principal IDs. Each gets Foundry User on the account and (when Search is present) Search Index Data Reader."
}

# Microsoft Foundry built-in role definition GUIDs (rename-safe).
# Source: https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry
locals {
  role_foundry_owner            = "c883944f-8b7b-4483-af10-35834be79c4a"
  role_foundry_project_manager  = "eadc314b-1a2d-4efa-be10-5d325db5065e"
  role_foundry_user             = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
  role_reader                   = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
  role_search_index_data_reader = "1407120a-92aa-4202-b7e9-c0e197c71c8f"

  # Filter project principal IDs to non-empty values (parity with Bicep's empty() gate per-iteration).
  project_pids = [for p in var.project_principal_ids : p if p != null && p != ""]
}

data "azurerm_client_config" "current" {}

###############################################################################
# Human group role assignments on the Foundry account
###############################################################################

resource "azurerm_role_assignment" "foundry_owner" {
  count              = var.foundry_admin_group_object_id == "" ? 0 : 1
  scope              = var.foundry_account_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_foundry_owner}"
  principal_id       = var.foundry_admin_group_object_id
  principal_type     = "Group"
  description        = "Foundry Owner for admin group (klz-accelerator post-deploy RBAC)."
}

resource "azurerm_role_assignment" "foundry_project_manager" {
  count              = var.foundry_lead_group_object_id == "" ? 0 : 1
  scope              = var.foundry_account_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_foundry_project_manager}"
  principal_id       = var.foundry_lead_group_object_id
  principal_type     = "Group"
  description        = "Foundry Project Manager for team-lead group (klz-accelerator post-deploy RBAC)."
}

resource "azurerm_role_assignment" "foundry_user_dev" {
  count              = var.foundry_developer_group_object_id == "" ? 0 : 1
  scope              = var.foundry_account_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_foundry_user}"
  principal_id       = var.foundry_developer_group_object_id
  principal_type     = "Group"
  description        = "Foundry User for developer group (klz-accelerator post-deploy RBAC)."
}

resource "azurerm_role_assignment" "foundry_reader" {
  count              = var.foundry_reader_group_object_id == "" ? 0 : 1
  scope              = var.foundry_account_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_reader}"
  principal_id       = var.foundry_reader_group_object_id
  principal_type     = "Group"
  description        = "Reader for auditor/SRE group (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Foundry account MI -> Search (account-level fallback / safety net)
# Mirrors Bicep raFoundryToSearch — most workloads use project MI (below) but
# this is harmless and covers any account-scoped runtime.
###############################################################################

resource "azurerm_role_assignment" "foundry_account_to_search" {
  count              = (var.search_service_id == "" || var.foundry_account_principal_id == "") ? 0 : 1
  scope              = var.search_service_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_search_index_data_reader}"
  principal_id       = var.foundry_account_principal_id
  principal_type     = "ServicePrincipal"
  description        = "Foundry account MI -> Search Index Data Reader (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Project MIs -> Foundry User on the Foundry account
# Without this, agent runs and BYOR data operations fail with 403 from the
# project context (Microsoft RBAC guidance).
###############################################################################

resource "azurerm_role_assignment" "project_foundry_user" {
  for_each           = { for i, pid in local.project_pids : pid => pid }
  scope              = var.foundry_account_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_foundry_user}"
  principal_id       = each.value
  principal_type     = "ServicePrincipal"
  description        = "Project MI -> Foundry User on parent account (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Project MIs -> Search Index Data Reader on AI Search
# BYOR Search connections execute under the project MI. This grant unblocks
# grounding / index queries from project agents.
# NOTE: READ-ONLY. For workflows that create or update Search indexes from a
# project, manually grant Search Index Data Contributor (8ebe5a00-...) or
# Search Service Contributor (7ca78c08-...) on top.
###############################################################################

resource "azurerm_role_assignment" "project_to_search" {
  for_each           = var.search_service_id == "" ? {} : { for i, pid in local.project_pids : pid => pid }
  scope              = var.search_service_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_search_index_data_reader}"
  principal_id       = each.value
  principal_type     = "ServicePrincipal"
  description        = "Project MI -> Search Index Data Reader (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Outputs
###############################################################################

output "assigned_foundry_owner" { value = var.foundry_admin_group_object_id != "" }
output "assigned_foundry_project_manager" { value = var.foundry_lead_group_object_id != "" }
output "assigned_foundry_user" { value = var.foundry_developer_group_object_id != "" }
output "assigned_foundry_reader" { value = var.foundry_reader_group_object_id != "" }
output "assigned_foundry_to_search" { value = var.search_service_id != "" && var.foundry_account_principal_id != "" }
output "assigned_project_mis" { value = length(local.project_pids) }
