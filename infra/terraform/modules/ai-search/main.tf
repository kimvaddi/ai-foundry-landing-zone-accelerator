###############################################################################
# ai-search — Standalone Azure AI Search service (+ optional private endpoint
# when chokepoint is enforced).
###############################################################################

variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "sku" {
  type    = string
  default = "basic"
}
variable "workspace_resource_id" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "public_network_access_enabled" {
  type        = bool
  default     = true
  description = "When false, Search is reachable only via private endpoint. Pair with var.pe_subnet_resource_id + DNS zone to keep it reachable."
}

variable "disable_local_auth" {
  type        = bool
  default     = false
  description = "Disable key-based auth (AAD only). Recommended when chokepoint is enforced."
}

variable "pe_subnet_resource_id" {
  type        = string
  default     = null
  description = "When non-null AND create_private_endpoint=true, create a private endpoint for the Search service in this subnet."
}

variable "create_private_endpoint" {
  type        = bool
  default     = false
  description = "Plan-time boolean gate for the private endpoint. Must be set explicitly (not derived from pe_subnet_resource_id which is unknown until apply when wired from a module output)."
}

variable "private_dns_zone_id" {
  type        = string
  default     = null
  description = "Resource ID of the privatelink.search.windows.net DNS zone for PE A-record registration."
}

resource "azurerm_search_service" "this" {
  name                          = substr(replace(var.name, "-", ""), 0, 60)
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.sku
  replica_count                 = 1
  partition_count               = 1
  local_authentication_enabled  = !var.disable_local_auth
  authentication_failure_mode   = var.disable_local_auth ? null : "http403"
  public_network_access_enabled = var.public_network_access_enabled
  semantic_search_sku           = var.sku == "free" ? null : "free"
  tags                          = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "search" {
  name                       = "diag-search"
  target_resource_id         = azurerm_search_service.this.id
  log_analytics_workspace_id = var.workspace_resource_id

  enabled_log { category = "OperationLogs" }
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_private_endpoint" "search" {
  count               = var.create_private_endpoint ? 1 : 0
  name                = "pe-srch-${substr(replace(var.name, "-", ""), 0, 32)}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_resource_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-search"
    private_connection_resource_id = azurerm_search_service.this.id
    is_manual_connection           = false
    subresource_names              = ["searchService"]
  }

  dynamic "private_dns_zone_group" {
    for_each = var.private_dns_zone_id != null ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = [var.private_dns_zone_id]
    }
  }
}

output "id" { value = azurerm_search_service.this.id }
output "name" { value = azurerm_search_service.this.name }
output "endpoint" { value = "https://${azurerm_search_service.this.name}.search.windows.net" }
output "private_endpoint_id" { value = try(azurerm_private_endpoint.search[0].id, null) }
