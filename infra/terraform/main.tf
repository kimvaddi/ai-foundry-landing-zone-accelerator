###############################################################################
# main.tf — klz-accelerator-finops Terraform orchestrator (p6, Option B)
#
# Topology mirrors infra/bicep/main.bicep, but composes the upstream AVM ptn
# modules where possible:
#
#   • Foundry stack (account + projects + Search/Cosmos/KV/Storage BYOR + PEs)
#       → Azure/avm-ptn-aiml-ai-foundry/azurerm (~ v0.10)
#   • Hub-greenfield landing zone (when network_mode = hub-greenfield)
#       → Azure/terraform-azurerm-avm-ptn-aiml-landing-zone (~ v0.7)
#   • Spoke VNet + 8/9 subnet catalog + NSGs + delegations
#       → ./modules/spoke-network (custom; mirrors Bicep spoke-vnet)
#   • APIM (variable SKU + optional VNet integration)
#       → ./modules/apim (custom wrapper around AVM apim resource module)
#   • Compute toggles (Bastion / JumpVM / BuildVM / AppGW WAF v2)
#       → ./modules/compute/{bastion,jumpvm,build-agent,app-gateway}
#   • Container Apps Environment
#       → ./modules/compute/cae
#   • Foundation (LAW + AppI + KV + DCRs)
#       → ./modules/foundation
#   • Observability (workbooks + alerts + notifications + OTel collector)
#       → ./modules/observability
#   • FinOps custom tables (LAW tables for pricing/quota/agent-audit)
#       → ./modules/finops
###############################################################################

# Resource groups
resource "azurerm_resource_group" "platform" {
  name     = local.resource_groups.platform
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "foundry" {
  name     = local.resource_groups.foundry
  location = var.location
  tags     = local.tags
}

# Foundation (LAW + AppI + KV + KV PE)
module "foundation" {
  source                 = "./modules/foundation"
  base_name              = local.base_name
  location               = var.location
  resource_group_name    = azurerm_resource_group.platform.name
  resource_group_id      = azurerm_resource_group.platform.id
  pe_subnet_id           = module.spoke_network.subnet_ids["PrivateEndpointSubnet"]
  kv_private_dns_zone_id = try(module.private_dns.zone_ids["vaultcore"], null)
  tags                   = local.tags
}

# Spoke VNet + subnet catalog + NSGs (always)
module "spoke_network" {
  source                    = "./modules/spoke-network"
  base_name                 = local.base_name
  location                  = var.location
  resource_group_name       = azurerm_resource_group.platform.name
  vnet_address_space        = var.vnet_address_space
  components                = var.components
  needs_firewall_subnet     = local.needs_firewall_subnet
  enforce_apim_chokepoint   = var.enforce_apim_chokepoint
  allow_cae_bypass          = var.allow_cae_bypass
  allow_agent_subnet_bypass = var.allow_agent_subnet_bypass
  tags                      = local.tags
}

# Private DNS zones (always, unless hub-connected provides them)
module "private_dns" {
  source                     = "./modules/private-dns"
  resource_group_name        = azurerm_resource_group.platform.name
  spoke_vnet_id              = module.spoke_network.vnet_id
  existing_private_dns_zones = var.existing_private_dns_zones
  link_to_spoke              = !local.is_hub_connected
  tags                       = local.tags
}

# Hub peering — spoke->hub (always) + optional hub->spoke reverse peer.
# Mirrors Bicep main.bicep:hubPeering. Only deploys when network_mode = hub-connected
# AND a hub VNet resource ID is supplied. Cross-sub reverse peer is silently skipped
# (parity with Bicep; needs nested deployments to land at the hub scope).
module "hub_peering" {
  count                        = local.hub_peering_enabled ? 1 : 0
  source                       = "./modules/hub-peering"
  spoke_vnet_name              = module.spoke_network.vnet_name
  spoke_resource_group_name    = azurerm_resource_group.platform.name
  spoke_vnet_id                = module.spoke_network.vnet_id
  hub_vnet_resource_id         = var.hub_vnet_resource_id
  peer_name_suffix             = "hub"
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
  create_reverse_hub_peer      = var.create_reverse_hub_peer
}

# Forced-tunnel UDR (0.0.0.0/0 -> hub firewall NVA) + per-subnet attachment.
# Mirrors Bicep main.bicep:routeTable + udrAttach loop. Only deploys when
# hub-connected, forced tunneling enabled, and a hub FW IP is provided.
module "route_table" {
  count                   = local.udr_should_deploy ? 1 : 0
  source                  = "./modules/route-table"
  base_name               = local.base_name
  location                = var.location
  resource_group_name     = azurerm_resource_group.platform.name
  hub_firewall_private_ip = var.hub_firewall_private_ip
  subnet_ids = {
    for k in local.udr_candidate_subnet_keys :
    k => module.spoke_network.subnet_ids[k]
  }
  tags = local.tags
}

# Hub greenfield (only when network_mode = hub-greenfield)
module "hub_greenfield" {
  count               = local.is_hub_greenfield ? 1 : 0
  source              = "./modules/hub-greenfield"
  base_name           = local.base_name
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  spoke_vnet_id       = module.spoke_network.vnet_id
  tags                = local.tags
}

# Foundry stack — AVM ptn
module "foundry_stack" {
  source            = "./modules/foundry-stack"
  base_name         = local.foundry_base_name
  location          = var.location
  resource_group_id = azurerm_resource_group.foundry.id

  projects                       = var.foundry_projects
  model_deployments              = var.model_deployments
  byor_connections               = local.effective_byor_connections
  enable_agent_injection         = var.enable_foundry_agent_injection
  agent_subnet_resource_id       = var.enable_foundry_agent_injection ? module.spoke_network.subnet_ids["AIFoundrySubnet"] : null
  create_account_capability_host = var.create_foundry_capability_host
  pe_subnet_resource_id          = module.spoke_network.subnet_ids["PrivateEndpointSubnet"]
  create_private_endpoints       = true
  workspace_resource_id          = module.foundation.workspace_resource_id
  tags                           = local.tags
}

###############################################################################
# Chokepoint enforcement (patches Foundry publicNetworkAccess = Disabled).
# AVM ptn module does not expose this property today; we patch via azapi after
# the account is created. Same pattern as foundry-stack's network_injections patch.
###############################################################################
resource "azapi_update_resource" "foundry_pna_disabled" {
  count       = var.enforce_apim_chokepoint ? 1 : 0
  type        = "Microsoft.CognitiveServices/accounts@2025-06-01"
  resource_id = module.foundry_stack.account_id

  body = {
    properties = {
      publicNetworkAccess = "Disabled"
    }
  }

  depends_on = [module.foundry_stack]
}

###############################################################################
# Chokepoint validation — fail fast if config is inconsistent.
###############################################################################
resource "terraform_data" "chokepoint_validation" {
  input = var.enforce_apim_chokepoint

  lifecycle {
    precondition {
      condition     = !var.enforce_apim_chokepoint || coalesce(try(local.c.apim.deploy, false), false)
      error_message = "enforce_apim_chokepoint = true requires components.apim.deploy = true."
    }
    precondition {
      condition     = !var.enforce_apim_chokepoint || (coalesce(try(local.c.apim.network_mode, "none"), "none") != "none")
      error_message = "enforce_apim_chokepoint = true requires components.apim.network_mode in {external, internal} so APIM can reach a private Foundry."
    }
    precondition {
      condition     = !var.enforce_apim_chokepoint || !coalesce(try(local.c.standalone_search.deploy, true), true) || local.search_location == var.location
      error_message = "enforce_apim_chokepoint = true with standalone Search requires search_location == location so a private endpoint can be attached. Either disable standalone Search, align regions, or turn chokepoint off."
    }
  }
}

# Standalone AI Search (separate from Foundry BYOR Search; consumed via project connection)
module "search" {
  count                         = coalesce(try(local.c.standalone_search.deploy, true), true) ? 1 : 0
  source                        = "./modules/ai-search"
  name                          = "srch-${local.base_name}"
  location                      = local.search_location
  resource_group_name           = azurerm_resource_group.foundry.name
  sku                           = coalesce(try(local.c.standalone_search.sku, "basic"), "basic")
  workspace_resource_id         = module.foundation.workspace_resource_id
  public_network_access_enabled = !var.enforce_apim_chokepoint
  disable_local_auth            = var.enforce_apim_chokepoint
  create_private_endpoint       = var.enforce_apim_chokepoint && local.search_location == var.location
  pe_subnet_resource_id         = var.enforce_apim_chokepoint && local.search_location == var.location ? module.spoke_network.subnet_ids["PrivateEndpointSubnet"] : null
  private_dns_zone_id           = var.enforce_apim_chokepoint ? try(module.private_dns.zone_ids["search"], null) : null
  tags                          = local.tags
}

# APIM (variable SKU + optional VNet integration)
module "apim" {
  count                    = coalesce(try(local.c.apim.deploy, false), false) ? 1 : 0
  source                   = "./modules/apim"
  base_name                = local.base_name
  location                 = var.location
  resource_group_name      = azurerm_resource_group.platform.name
  sku                      = coalesce(try(local.c.apim.sku, "StandardV2"), "StandardV2")
  network_mode             = coalesce(try(local.c.apim.network_mode, "none"), "none")
  subnet_id                = local.apim_wants_subnet ? module.spoke_network.subnet_ids["APIMSubnet"] : null
  public_ip_id             = local.apim_wants_subnet ? module.spoke_network.apim_pip_id : null
  publisher_email          = "${var.apim_publisher.local_part}@${var.apim_publisher.domain}"
  publisher_name           = var.apim_publisher.name
  app_insights_id          = module.foundation.app_insights_id
  app_insights_conn_string = module.foundation.app_insights_connection_string
  workspace_resource_id    = module.foundation.workspace_resource_id
  foundry_endpoint         = module.foundry_stack.account_endpoint
  foundry_account_id       = module.foundry_stack.account_id

  # Safety + semantic-cache toggles (parity with Bicep)
  enable_content_safety      = var.enable_content_safety
  enable_prompt_shields      = var.enable_prompt_shields
  safety_threshold           = var.safety_threshold
  enable_semantic_cache      = var.enable_semantic_cache
  embeddings_deployment_name = var.embeddings_deployment_name
  product_tokens_per_minute  = var.apim_product_tokens_per_minute
  redis_connection_string    = var.enable_semantic_cache ? module.redis_cache[0].connection_string : ""

  tags = local.tags
}

# Redis Enterprise — backing store for APIM semantic cache. Adds ~$8.6/day.
module "redis_cache" {
  count               = var.enable_semantic_cache ? 1 : 0
  source              = "./modules/redis-enterprise"
  name                = substr("rec-${local.base_name}", 0, 60)
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = local.tags
}

# Compute toggles
module "bastion" {
  count               = coalesce(try(local.c.bastion.deploy, false), false) ? 1 : 0
  source              = "./modules/compute/bastion"
  base_name           = local.base_name
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  vnet_id             = module.spoke_network.vnet_id
  workspace_id        = module.foundation.workspace_resource_id
  sku                 = coalesce(try(local.c.bastion.sku, "Standard"), "Standard")
  tags                = local.tags
}

module "jumpvm" {
  count               = coalesce(try(local.c.jumpvm.deploy, false), false) ? 1 : 0
  source              = "./modules/compute/jumpvm"
  base_name           = local.base_name
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = module.spoke_network.subnet_ids["JumpboxSubnet"]
  vm_size             = coalesce(try(local.c.jumpvm.sku, "Standard_B2s"), "Standard_B2s")
  admin_password      = var.jumpvm_admin_password
  tags                = local.tags
}

module "buildvm" {
  count               = coalesce(try(local.c.buildvm.deploy, false), false) ? 1 : 0
  source              = "./modules/compute/build-agent"
  base_name           = local.base_name
  location            = var.location
  resource_group_name = azurerm_resource_group.platform.name
  subnet_id           = module.spoke_network.subnet_ids["DevOpsBuildSubnet"]
  vm_size             = coalesce(try(local.c.buildvm.sku, "Standard_B2s"), "Standard_B2s")
  ssh_public_key      = var.buildvm_ssh_public_key
  tags                = local.tags
}

module "app_gateway" {
  count                 = coalesce(try(local.c.app_gateway.deploy, false), false) ? 1 : 0
  source                = "./modules/compute/app-gateway"
  base_name             = local.base_name
  location              = var.location
  resource_group_name   = azurerm_resource_group.platform.name
  subnet_id             = module.spoke_network.subnet_ids["AppGatewaySubnet"]
  sku                   = coalesce(try(local.c.app_gateway.sku, "WAF_v2"), "WAF_v2")
  waf_enabled           = coalesce(try(local.c.app_gateway.waf_enabled, true), true)
  workspace_resource_id = module.foundation.workspace_resource_id
  tags                  = local.tags
}

module "container_apps_env" {
  count                          = coalesce(try(local.c.container_apps_env.deploy, false), false) ? 1 : 0
  source                         = "./modules/compute/cae"
  base_name                      = local.base_name
  location                       = var.location
  resource_group_name            = azurerm_resource_group.platform.name
  workspace_resource_id          = module.foundation.workspace_resource_id
  infrastructure_subnet_id       = module.spoke_network.subnet_ids["ContainerAppEnvironmentSubnet"]
  internal_load_balancer_enabled = var.container_apps_env_internal
  tags                           = local.tags
}

# Observability stack — workbooks + 1-2 scheduled query alerts + optional action group
module "observability" {
  source                = "./modules/observability"
  base_name             = local.base_name
  location              = var.location
  resource_group_name   = azurerm_resource_group.platform.name
  workspace_resource_id = module.foundation.workspace_resource_id
  deploy_notifications  = var.deploy_notifications
  deploy_cost_alert     = var.deploy_cost_alert
  tags                  = local.tags
}

###############################################################################
# VNet + NSG diagnostic settings (mirrors Bicep spoke-vnet.bicep AVM
# diagnosticSettings blocks). Created at the root level — NOT inside the
# spoke-network module — to avoid a module dep cycle (foundation depends
# on spoke-network subnets; spoke-network would depend on foundation
# workspace).
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "spoke_vnet_metrics" {
  name                       = "send-to-law"
  target_resource_id         = module.spoke_network.vnet_id
  log_analytics_workspace_id = module.foundation.workspace_resource_id

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "spoke_nsg" {
  for_each                   = module.spoke_network.nsg_ids
  name                       = "send-to-law"
  target_resource_id         = each.value
  log_analytics_workspace_id = module.foundation.workspace_resource_id

  enabled_log {
    category_group = "allLogs"
  }
}

# FinOps custom tables + 3 DCRs (always) — mirrors Bicep names+schemas
module "finops" {
  source                = "./modules/finops"
  location              = var.location
  resource_group_name   = azurerm_resource_group.platform.name
  workspace_resource_id = module.foundation.workspace_resource_id
  workspace_name        = module.foundation.workspace_name
  tags                  = local.tags
}

###############################################################################
# Post-deploy RBAC (opt-in) — mirrors Bicep main.bicep postRbacFoundry +
# postRbacPlatform. Each sub-module gates individual role assignments with
# empty-string checks on principal IDs, so partial configurations are valid.
#
# For backward compatibility with Bicep: when foundry_reader_group_object_id
# is empty, the platform reader group is reused for Foundry Reader.
###############################################################################

module "rbac_foundry" {
  count                             = var.enable_post_deploy_rbac ? 1 : 0
  source                            = "./modules/rbac-foundry-scope"
  foundry_account_id                = module.foundry_stack.account_id
  search_service_id                 = length(module.search) > 0 ? module.search[0].id : ""
  foundry_admin_group_object_id     = var.foundry_admin_group_object_id
  foundry_lead_group_object_id      = var.foundry_lead_group_object_id
  foundry_developer_group_object_id = var.foundry_developer_group_object_id
  foundry_reader_group_object_id    = var.foundry_reader_group_object_id != "" ? var.foundry_reader_group_object_id : var.platform_reader_group_object_id
  foundry_account_principal_id      = coalesce(module.foundry_stack.account_principal_id, "")
  project_principal_ids             = module.foundry_stack.project_principal_ids
}

module "rbac_platform" {
  count                           = var.enable_post_deploy_rbac ? 1 : 0
  source                          = "./modules/rbac-platform-scope"
  resource_group_id               = azurerm_resource_group.platform.id
  key_vault_id                    = module.foundation.key_vault_id
  platform_reader_group_object_id = var.platform_reader_group_object_id
  deployment_spn_object_id        = var.deployment_spn_object_id
  jump_vm_principal_id            = length(module.jumpvm) > 0 ? module.jumpvm[0].principal_id : ""
  build_vm_principal_id           = length(module.buildvm) > 0 ? module.buildvm[0].principal_id : ""
}
