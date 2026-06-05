###############################################################################
# foundry-stack — AI Foundry account + projects + connections + caphost
#
# This module composes Azure/avm-ptn-aiml-ai-foundry/azurerm (v0.10) for the
# account + AVM-managed BYOR resources, and layers on:
#   • multi-project loop (the AVM ptn only creates 1 project)
#   • per-project BYOR connections (CognitiveSearch / CosmosDB / AzureStorage / AzureKeyVault)
#   • optional account-level capabilityHost (kind = Agents) when
#     var.create_account_capability_host = true
#   • Foundry account purge on destroy (handled by the AVM ptn + azapi action)
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_id" { type = string }

variable "projects" {
  type = list(object({
    name         = string
    display_name = string
    description  = string
  }))
}

variable "model_deployments" {
  type = list(object({
    name = string
    model = object({
      format  = string
      name    = string
      version = string
    })
    sku = object({
      name     = string
      capacity = number
    })
  }))
  default = []
}

variable "byor_connections" {
  type = list(object({
    project_name     = string
    name             = string
    category         = string
    target           = optional(string, "")
    auth_type        = optional(string, "AAD")
    is_shared_to_all = optional(bool, true)
    metadata         = optional(map(string), {})
  }))
  default = []
}

variable "enable_agent_injection" {
  type    = bool
  default = false
}
variable "agent_subnet_resource_id" {
  type    = string
  default = null
}
variable "create_account_capability_host" {
  type    = bool
  default = false
}
variable "pe_subnet_resource_id" {
  type    = string
  default = null
}
variable "create_private_endpoints" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = null
}

locals {
  account_name = "aif-${var.base_name}"

  # AVM Foundry ptn expects ai_model_deployments as a map keyed by deployment name
  model_deployments_map = {
    for d in var.model_deployments : d.name => {
      name  = d.name
      model = d.model
      scale = {
        type     = d.sku.name == "GlobalStandard" ? "GlobalStandard" : "Standard"
        capacity = d.sku.capacity
      }
    }
  }
}

# AVM ptn — creates: AI Foundry account, the FIRST project, plus BYOR + PEs
module "ptn" {
  source  = "Azure/avm-ptn-aiml-ai-foundry/azurerm"
  version = "~> 0.10"

  base_name                                = var.base_name
  location                                 = var.location
  resource_group_resource_id               = var.resource_group_id
  ai_model_deployments                     = local.model_deployments_map
  create_byor                              = true
  create_private_endpoints                 = var.create_private_endpoints
  private_endpoint_subnet_resource_id      = var.pe_subnet_resource_id
  private_endpoints_manage_dns_zone_groups = var.create_private_endpoints
  enable_telemetry                         = false
  tags                                     = var.tags

  resource_names = {
    ai_foundry                      = local.account_name
    ai_foundry_project              = "proj-${var.projects[0].name}"
    ai_foundry_project_display_name = var.projects[0].display_name
  }

  diagnostic_settings = {}
}

# Account-level network injection (agent service) — patched after AVM ptn settles.
# NOTE: `count` predicate cannot reference apply-time values (the subnet ID is unknown
# at plan when the spoke VNet is being created in the same apply). Gate ONLY on the
# user toggle; if the subnet ID happens to be empty at apply, azapi will error clearly.
resource "azapi_update_resource" "network_injections" {
  count       = var.enable_agent_injection ? 1 : 0
  type        = "Microsoft.CognitiveServices/accounts@2025-06-01"
  resource_id = module.ptn.ai_foundry_id

  body = {
    properties = {
      networkInjections = [{
        scenario                   = "agent"
        subnetArmId                = var.agent_subnet_resource_id
        useMicrosoftManagedNetwork = false
      }]
    }
  }
}

# Projects: AVM ptn does NOT create projects unless var.ai_projects is passed (we
# don't pass it — it's a complex object). Create ALL projects via azapi instead.
resource "azapi_resource" "extra_projects" {
  for_each  = { for p in var.projects : p.name => p }
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = "proj-${each.value.name}"
  parent_id = module.ptn.ai_foundry_id
  location  = var.location

  body = {
    properties = {
      displayName = each.value.display_name
      description = each.value.description
    }
    identity = { type = "SystemAssigned" }
  }

  response_export_values = ["id", "identity"]

  depends_on = [azapi_update_resource.network_injections]
}

# Per-project BYOR connections (CognitiveSearch / CosmosDB / AzureStorage / AzureKeyVault)
locals {
  # Map of all project name → project resource ID (all from azapi)
  all_project_ids = { for k, p in azapi_resource.extra_projects : k => p.id }

  # Filter BYOR connections to those targeting known projects
  effective_byor = [
    for c in var.byor_connections : c
    if contains(keys(local.all_project_ids), c.project_name)
  ]
}

resource "azapi_resource" "project_connection" {
  for_each  = { for idx, c in local.effective_byor : "${c.project_name}__${c.name}" => c }
  type      = "Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01"
  name      = each.value.name
  parent_id = local.all_project_ids[each.value.project_name]

  body = {
    properties = {
      category      = each.value.category
      target        = each.value.target
      authType      = each.value.auth_type
      isSharedToAll = each.value.is_shared_to_all
      metadata      = each.value.metadata
    }
  }

  depends_on = [azapi_resource.extra_projects]
}

# Optional account-level capabilityHost (kind = Agents)
resource "azapi_resource" "account_capability_host" {
  count     = var.create_account_capability_host ? 1 : 0
  type      = "Microsoft.CognitiveServices/accounts/capabilityHosts@2025-06-01"
  name      = "caphost-default"
  parent_id = module.ptn.ai_foundry_id

  body = {
    properties = merge(
      { capabilityHostKind = "Agents" },
      var.agent_subnet_resource_id != null ? { customerSubnet = var.agent_subnet_resource_id } : {}
    )
  }

  timeouts {
    create = "60m"
    delete = "30m"
  }

  depends_on = [
    azapi_update_resource.network_injections,
    azapi_resource.project_connection,
  ]
}

output "account_id" { value = module.ptn.ai_foundry_id }
output "account_name" { value = local.account_name }
output "account_endpoint" { value = "https://${local.account_name}.cognitiveservices.azure.com/" }
output "project_ids" { value = local.all_project_ids }
