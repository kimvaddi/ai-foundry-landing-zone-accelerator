###############################################################################
# compute/app-gateway — Application Gateway WAF v2 + PIP + WAF policy
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id" { type = string }
variable "sku" {
  type    = string
  default = "WAF_v2"
}
variable "waf_enabled" {
  type    = bool
  default = true
}
variable "workspace_resource_id" {
  type    = string
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_public_ip" "appgw" {
  name                = "pip-agw-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  domain_name_label   = "agw-${var.base_name}"
  tags                = var.tags
}

resource "azurerm_web_application_firewall_policy" "this" {
  count               = var.waf_enabled ? 1 : 0
  name                = "wafpol-agw-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

resource "azurerm_application_gateway" "this" {
  name                = "agw-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
  zones               = ["1", "2", "3"]
  enable_http2        = true
  firewall_policy_id  = var.waf_enabled ? azurerm_web_application_firewall_policy.this[0].id : null

  sku {
    name = var.sku
    tier = var.sku
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 3
  }

  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = var.subnet_id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appGatewayFrontendIP"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name = "default-backend-pool"
  }

  backend_http_settings {
    name                  = "default-backend-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
  }

  http_listener {
    name                           = "default-listener"
    frontend_ip_configuration_name = "appGatewayFrontendIP"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "default-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "default-listener"
    backend_address_pool_name  = "default-backend-pool"
    backend_http_settings_name = "default-backend-settings"
  }
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "diag-agw"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.workspace_resource_id

  enabled_log { category = "ApplicationGatewayAccessLog" }
  enabled_log { category = "ApplicationGatewayPerformanceLog" }
  enabled_log { category = "ApplicationGatewayFirewallLog" }
  enabled_metric { category = "AllMetrics" }
}

output "id" { value = azurerm_application_gateway.this.id }
output "name" { value = azurerm_application_gateway.this.name }
output "public_ip" { value = azurerm_public_ip.appgw.ip_address }
