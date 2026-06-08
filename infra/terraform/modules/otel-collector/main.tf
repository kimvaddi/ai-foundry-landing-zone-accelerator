###############################################################################
# otel-collector — OpenTelemetry Collector deployed as a Container App.
#
# Mirrors infra/bicep/modules/observability/otel-collector.bicep 1:1. Receives
# OTLP traces/metrics from agent runtimes (via observability/otel-genai/python-
# instrumentation.py) and forwards to Application Insights + optional secondary
# OTLP endpoint (e.g. Datadog, Honeycomb).
###############################################################################

variable "name" {
  type        = string
  description = "Container App name (e.g. ca-otel-<basename>)."
}

# Kept for Bicep parity (otel-collector.bicep declares `location`); Container
# Apps inherit location from environment_id at the azurerm provider layer.
# tflint-ignore: terraform_unused_declarations
variable "location" { type = string }
variable "resource_group_name" { type = string }

variable "environment_id" {
  type        = string
  description = "Resource ID of the Azure Container Apps managed environment (caller provides; CAE shared with var.components.container_apps_env)."
}

variable "image" {
  type        = string
  default     = "mcr.microsoft.com/azuremonitor/containerinsights/cidev/applicationinsights-opentelemetry-collector:latest"
  description = "Container image. Pin a digest in production."
}

variable "app_insights_connection_string" {
  type        = string
  sensitive   = true
  description = "App Insights connection string (foundation module output)."
}

variable "secondary_otlp_endpoint" {
  type        = string
  default     = ""
  description = "Optional secondary OTLP endpoint (gRPC). Leave empty to skip."
}

variable "cpu" {
  type        = string
  default     = "0.5"
  description = "CPU cores per replica."
}

variable "memory" {
  type        = string
  default     = "1Gi"
  description = "Memory per replica."
}

variable "min_replicas" {
  type        = number
  default     = 0
  description = "Minimum replicas (scale-to-zero allowed)."
}

variable "max_replicas" {
  type        = number
  default     = 3
  description = "Maximum replicas."
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_container_app" "this" {
  name                         = var.name
  container_app_environment_id = var.environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  secret {
    name  = "appinsights-connection-string"
    value = var.app_insights_connection_string
  }

  # OTLP gRPC ingress (4317) — internal-only by default.
  ingress {
    external_enabled = false
    target_port      = 4317
    transport        = "tcp"
    exposed_port     = 4317

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "otel-collector"
      image  = var.image
      cpu    = tonumber(var.cpu)
      memory = var.memory

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
      env {
        name  = "KLZ_SECONDARY_OTLP_ENDPOINT"
        value = var.secondary_otlp_endpoint
      }

      liveness_probe {
        transport        = "TCP"
        port             = 13133
        initial_delay    = 10
        interval_seconds = 30
      }

      readiness_probe {
        transport        = "TCP"
        port             = 13133
        interval_seconds = 10
      }
    }

    custom_scale_rule {
      name             = "cpu-scale"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }

  tags = merge(var.tags, {
    "klz:component" = "otel-collector"
  })
}

output "container_app_id" { value = azurerm_container_app.this.id }
output "principal_id" { value = azurerm_container_app.this.identity[0].principal_id }
output "internal_fqdn" { value = azurerm_container_app.this.ingress[0].fqdn }
