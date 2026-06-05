###############################################################################
# private-dns — 21 PDNS zones (in-spoke creation OR reference existing from hub)
#
# Mirrors infra/bicep/modules/networking/private-dns.bicep. When the caller
# supplies var.existing_private_dns_zones[fqdn] = resource_id, the zone is
# reused; otherwise a new zone is created in the platform RG. When
# var.link_to_spoke = true, every zone (created or referenced) is linked to
# the spoke VNet.
###############################################################################

variable "resource_group_name" { type = string }
variable "spoke_vnet_id" { type = string }
variable "existing_private_dns_zones" {
  type    = map(string)
  default = {}
}
variable "link_to_spoke" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  zones = {
    vaultcore         = "privatelink.vaultcore.azure.net"
    apim              = "privatelink.azure-api.net"
    cosmosSql         = "privatelink.documents.azure.com"
    cosmosMongo       = "privatelink.mongo.cosmos.azure.com"
    cosmosCassandra   = "privatelink.cassandra.cosmos.azure.com"
    cosmosGremlin     = "privatelink.gremlin.cosmos.azure.com"
    cosmosTable       = "privatelink.table.cosmos.azure.com"
    cosmosAnalytics   = "privatelink.analytics.cosmos.azure.com"
    cosmosPostgres    = "privatelink.postgres.cosmos.azure.com"
    blob              = "privatelink.blob.core.windows.net"
    queue             = "privatelink.queue.core.windows.net"
    table             = "privatelink.table.core.windows.net"
    file              = "privatelink.file.core.windows.net"
    dfs               = "privatelink.dfs.core.windows.net"
    web               = "privatelink.web.core.windows.net"
    search            = "privatelink.search.windows.net"
    acr               = "privatelink.azurecr.io"
    appConfig         = "privatelink.azconfig.io"
    openai            = "privatelink.openai.azure.com"
    aiServices        = "privatelink.services.ai.azure.com"
    cognitiveServices = "privatelink.cognitiveservices.azure.com"
  }

  # Split zones into create vs reference
  create_zones   = { for k, fqdn in local.zones : k => fqdn if !contains(keys(var.existing_private_dns_zones), fqdn) }
  existing_zones = { for k, fqdn in local.zones : k => var.existing_private_dns_zones[fqdn] if contains(keys(var.existing_private_dns_zones), fqdn) }

  spoke_segments  = split("/", var.spoke_vnet_id)
  spoke_vnet_name = element(local.spoke_segments, length(local.spoke_segments) - 1)
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = local.create_zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Link spoke VNet to zones we just created
resource "azurerm_private_dns_zone_virtual_network_link" "created" {
  for_each              = var.link_to_spoke ? local.create_zones : {}
  name                  = "link-${local.spoke_vnet_name}-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = var.spoke_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# Link spoke VNet to existing (hub) zones — uses azapi so we can target the
# zone's own RG without needing a data source per zone.
resource "azapi_resource" "link_existing" {
  for_each  = var.link_to_spoke ? local.existing_zones : {}
  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01"
  name      = "link-${local.spoke_vnet_name}-${each.key}"
  parent_id = each.value
  location  = "global"
  body = {
    properties = {
      virtualNetwork      = { id = var.spoke_vnet_id }
      registrationEnabled = false
    }
  }
  tags = var.tags
}

# Map of zone-key → resource ID (whether created or referenced)
output "zone_ids" {
  value = merge(
    { for k, z in azurerm_private_dns_zone.this : k => z.id },
    local.existing_zones,
  )
}

# Map of zone-key → fqdn (always known)
output "zone_fqdns" {
  value = local.zones
}
