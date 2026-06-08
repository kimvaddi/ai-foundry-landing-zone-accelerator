###############################################################################
# locals.tf — naming, computed booleans, and merged tags
###############################################################################

locals {
  # ----- Naming -----
  # Stable suffix derived from workload+env (mirrors Bicep `nameSuffix`).
  name_suffix = substr(sha256("${var.workload}${var.environment}${data.azurerm_client_config.current.subscription_id}"), 0, 4)
  base_name   = "${var.workload}-${var.environment}-${local.name_suffix}"

  # AVM Foundry ptn validation requires base_name in 3-7 chars [a-z0-9-].
  # Compose from first 3 chars of workload + 4-char hash suffix = exactly 7.
  foundry_base_name = "${substr(var.workload, 0, 3)}${local.name_suffix}"

  resource_groups = {
    platform = "rg-${var.workload}-platform-${var.environment}${var.rg_suffix}"
    foundry  = "rg-${var.workload}-foundry-${var.environment}${var.rg_suffix}"
  }

  # ----- Tag merge -----
  base_tags = {
    workload  = var.workload
    env       = var.environment
    managedBy = "klz-accelerator-finops"
    iacStack  = "terraform"
  }
  tags = merge(local.base_tags, var.tags)

  # ----- Network-mode booleans (mirrors Bicep `var net*` flags) -----
  is_with_firewall      = var.network_mode == "standalone-with-firewall"
  is_hub_connected      = var.network_mode == "hub-connected"
  is_hub_greenfield     = var.network_mode == "hub-greenfield"
  needs_firewall_subnet = local.is_with_firewall || local.is_hub_greenfield

  # ----- Components defaults (with safe access) -----
  c = var.components

  # Search location fallback
  search_location = coalesce(var.search_location, var.location)

  # Computed APIM externalness (for the spoke-vnet APIM subnet delegation)
  apim_wants_subnet = (
    coalesce(try(local.c.apim.deploy, false), false)
    && coalesce(try(local.c.apim.network_mode, "none"), "none") != "none"
  )

  # Standalone Search endpoint (computed from name pattern; consumed by BYOR auto-wire)
  default_search_endpoint = (
    var.auto_wire_search_connection && coalesce(try(local.c.standalone_search.deploy, true), true)
    ? "https://srch-${local.base_name}.search.windows.net"
    : ""
  )

  # Effective BYOR connections — fill empty CognitiveSearch targets when auto-wire is on
  effective_byor_connections = [
    for c in var.foundry_byor_connections : merge(
      c,
      {
        target = (
          c.target == "" && c.category == "CognitiveSearch" && local.default_search_endpoint != ""
          ? local.default_search_endpoint
          : c.target
        )
      }
    )
  ]

  # ----- Hub-connected gates (mirror Bicep main.bicep:hubPeering + udrShouldDeploy) -----
  hub_peering_enabled = local.is_hub_connected && var.hub_vnet_resource_id != ""
  udr_should_deploy   = local.is_hub_connected && var.enable_forced_tunneling && var.hub_firewall_private_ip != ""

  # UDR-attachable subnet list — mirrors Bicep `udrCandidateSubnets`.
  # Always AIFoundrySubnet; toggle-gated APIMSubnet / AppGatewaySubnet /
  # ContainerAppEnvironmentSubnet / DevOpsBuildSubnet / JumpboxSubnet.
  # Never PrivateEndpointSubnet, AzureBastionSubnet, AzureFirewallSubnet.
  udr_candidate_subnet_keys = compact(concat(
    ["AIFoundrySubnet"],
    local.apim_wants_subnet ? ["APIMSubnet"] : [],
    coalesce(try(local.c.app_gateway.deploy, false), false) ? ["AppGatewaySubnet"] : [],
    coalesce(try(local.c.container_apps_env.deploy, false), false) ? ["ContainerAppEnvironmentSubnet"] : [],
    coalesce(try(local.c.buildvm.deploy, false), false) ? ["DevOpsBuildSubnet"] : [],
    coalesce(try(local.c.jumpvm.deploy, false), false) ? ["JumpboxSubnet"] : [],
  ))
}

data "azurerm_client_config" "current" {}
