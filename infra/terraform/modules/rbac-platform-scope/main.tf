###############################################################################
# rbac-platform-scope — Post-deploy RBAC at the platform resource group scope.
#
# Mirrors infra/bicep/modules/security/rbac-platform-scope.bicep exactly.
# Wires up:
#   * Reader on the platform RG for the auditor/SRE/FinOps group
#   * Contributor on the platform RG for the CI/CD deployment SPN
#   * Key Vault Secrets User on the foundation KV for jump + build VM MIs
###############################################################################

variable "resource_group_id" {
  type        = string
  description = "Full resource ID of the platform resource group."
}

variable "key_vault_id" {
  type        = string
  default     = ""
  description = "Full resource ID of the foundation Key Vault. Empty to skip KV role grants."
}

variable "platform_reader_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Reader on the platform RG. Empty to skip."
}

variable "deployment_spn_object_id" {
  type        = string
  default     = ""
  description = "Service principal object ID -> Contributor on the platform RG (CI/CD pipelines). Empty to skip."
}

variable "jump_vm_principal_id" {
  type        = string
  default     = ""
  description = "Jump VM system-assigned MI principal ID. Empty to skip KV Secrets User grant."
}

variable "build_vm_principal_id" {
  type        = string
  default     = ""
  description = "Build agent VM system-assigned MI principal ID. Empty to skip KV Secrets User grant."
}

locals {
  role_reader                 = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
  role_contributor            = "b24988ac-6180-42a0-ab88-20f7382dd24c"
  role_key_vault_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"
}

data "azurerm_client_config" "current" {}

###############################################################################
# Resource group scoped human/SPN role assignments
###############################################################################

resource "azurerm_role_assignment" "platform_reader" {
  count              = var.platform_reader_group_object_id == "" ? 0 : 1
  scope              = var.resource_group_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_reader}"
  principal_id       = var.platform_reader_group_object_id
  principal_type     = "Group"
  description        = "Reader on platform RG (klz-accelerator post-deploy RBAC)."
}

resource "azurerm_role_assignment" "deployment_spn" {
  count              = var.deployment_spn_object_id == "" ? 0 : 1
  scope              = var.resource_group_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_contributor}"
  principal_id       = var.deployment_spn_object_id
  principal_type     = "ServicePrincipal"
  description        = "Contributor on platform RG for CI/CD SPN (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Key Vault Secrets User for VM MIs
###############################################################################

resource "azurerm_role_assignment" "jump_vm_kv" {
  count              = (var.key_vault_id == "" || var.jump_vm_principal_id == "") ? 0 : 1
  scope              = var.key_vault_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_key_vault_secrets_user}"
  principal_id       = var.jump_vm_principal_id
  principal_type     = "ServicePrincipal"
  description        = "Jump VM MI -> Key Vault Secrets User (klz-accelerator post-deploy RBAC)."
}

resource "azurerm_role_assignment" "build_vm_kv" {
  count              = (var.key_vault_id == "" || var.build_vm_principal_id == "") ? 0 : 1
  scope              = var.key_vault_id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_key_vault_secrets_user}"
  principal_id       = var.build_vm_principal_id
  principal_type     = "ServicePrincipal"
  description        = "Build VM MI -> Key Vault Secrets User (klz-accelerator post-deploy RBAC)."
}

###############################################################################
# Outputs
###############################################################################

output "assigned_reader" { value = var.platform_reader_group_object_id != "" }
output "assigned_contributor" { value = var.deployment_spn_object_id != "" }
output "assigned_jump_kv" { value = var.key_vault_id != "" && var.jump_vm_principal_id != "" }
output "assigned_build_kv" { value = var.key_vault_id != "" && var.build_vm_principal_id != "" }
