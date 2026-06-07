###############################################################################
# apim — API Management with variable SKU and optional VNet integration
# AI API + product + foundry-openai backend + policy chain (assembled XML)
# Toggleable: content safety, prompt shields, semantic cache, RBAC
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "sku" {
  type    = string
  default = "StandardV2"
}
variable "network_mode" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["none", "external", "internal"], var.network_mode)
    error_message = "network_mode must be none | external | internal."
  }
}
variable "subnet_id" {
  type    = string
  default = null
}
variable "public_ip_id" {
  type    = string
  default = null
}
variable "publisher_email" { type = string }
variable "publisher_name" { type = string }
variable "app_insights_id" {
  type    = string
  default = null
}
variable "app_insights_conn_string" {
  type      = string
  default   = null
  sensitive = true
}
variable "workspace_resource_id" {
  type    = string
  default = null
}
variable "foundry_endpoint" {
  type    = string
  default = null
}
variable "foundry_account_id" {
  type    = string
  default = null
}

# ---------------- AI API + safety + cache toggles -----------------------
variable "product_tokens_per_minute" {
  type        = number
  default     = 50000
  description = "Per-product TPM cap. Templated into product-token-limit.xml."
}
variable "enable_content_safety" {
  type        = bool
  default     = false
  description = "Adds llm-content-safety element (category scoring) + content-safety-backend."
}
variable "enable_prompt_shields" {
  type        = bool
  default     = false
  description = "Adds shield-prompt=true to the same llm-content-safety element."
}
variable "safety_threshold" {
  type    = number
  default = 4
  validation {
    condition     = contains([0, 2, 4, 6], var.safety_threshold)
    error_message = "safety_threshold must be 0, 2, 4, or 6 (FourSeverityLevels)."
  }
}
variable "content_safety_endpoint" {
  type        = string
  default     = null
  description = "Defaults to foundry_endpoint when null."
}
variable "content_safety_resource_id" {
  type        = string
  default     = null
  description = "Defaults to foundry_account_id when null."
}
variable "enable_semantic_cache" {
  type        = bool
  default     = false
  description = "Adds semantic-cache lookup/store + embeddings-backend. Requires redis_connection_string."
}
variable "redis_connection_string" {
  type      = string
  default   = ""
  sensitive = true
}
variable "embeddings_deployment_name" {
  type    = string
  default = "text-embedding-3-large"
}

variable "enable_foundry_rbac" {
  type        = bool
  default     = true
  description = "Assign APIM SAMI -> Cognitive Services User on the foundry account. Default true. Disable only when RBAC is managed externally."
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  sku_capacity = {
    BasicV2    = "BasicV2_1"
    StandardV2 = "StandardV2_1"
    Premium    = "Premium_1"
  }
  sku_string = lookup(local.sku_capacity, var.sku, "StandardV2_1")
  vnet_type  = var.network_mode == "none" ? "None" : (var.network_mode == "internal" ? "Internal" : "External")

  # Default content-safety endpoint/resource to Foundry (kind=AIServices includes /contentsafety/*).
  cs_endpoint    = coalesce(var.content_safety_endpoint, var.foundry_endpoint)
  cs_resource_id = coalesce(var.content_safety_resource_id, var.foundry_account_id)

  policies_root = "${path.module}/../../../../apim-policies"

  # --- Assemble API policy XML via chained replace() to avoid HCL/APIM
  # template syntax clashes (APIM uses ${var} and @(expr) in policies which
  # collides with Terraform's templatefile()). Reading raw via file() and
  # using replace() keeps the source-of-truth fragments untouched.
  cs_fragment_raw = file("${local.policies_root}/fragments/llm-content-safety.inbound.xml")
  cs_fragment = (var.enable_content_safety || var.enable_prompt_shields) ? replace(
    replace(local.cs_fragment_raw, "__SHIELD_PROMPT__", var.enable_prompt_shields ? "true" : "false"),
    "__SAFETY_THRESHOLD__", tostring(var.safety_threshold)
  ) : ""
  sc_inbound_fragment  = var.enable_semantic_cache ? file("${local.policies_root}/fragments/semantic-cache.inbound.xml") : ""
  sc_outbound_fragment = var.enable_semantic_cache ? file("${local.policies_root}/fragments/semantic-cache.outbound.xml") : ""

  api_policy = replace(
    replace(
      replace(
        file("${local.policies_root}/fragments/api-policy.xml.tpl"),
        "__CONTENT_SAFETY_INBOUND__", local.cs_fragment
      ),
      "__SEMANTIC_CACHE_INBOUND__", local.sc_inbound_fragment
    ),
    "__SEMANTIC_CACHE_OUTBOUND__", local.sc_outbound_fragment
  )

  product_policy = replace(
    file("${local.policies_root}/product-token-limit.xml"),
    "__TOKENS_PER_MINUTE__", tostring(var.product_tokens_per_minute)
  )

  service_policy = file("${local.policies_root}/inbound-emit-metrics.xml")
}

resource "azurerm_api_management" "this" {
  name                 = "apim-${var.base_name}"
  location             = var.location
  resource_group_name  = var.resource_group_name
  publisher_email      = var.publisher_email
  publisher_name       = var.publisher_name
  sku_name             = local.sku_string
  virtual_network_type = local.vnet_type
  public_ip_address_id = var.network_mode == "external" ? var.public_ip_id : null
  tags                 = var.tags

  identity { type = "SystemAssigned" }

  dynamic "virtual_network_configuration" {
    for_each = var.network_mode == "none" ? [] : [1]
    content {
      subnet_id = var.subnet_id
    }
  }
}

# ---------------- Service-scope inbound policy --------------------------
resource "azurerm_api_management_policy" "service" {
  api_management_id = azurerm_api_management.this.id
  xml_content       = local.service_policy
}

# ---------------- Foundry openai backend (azapi for circuit breaker) ----
resource "azapi_resource" "foundry_backend" {
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  parent_id = azurerm_api_management.this.id
  name      = "foundry-openai"
  body = {
    properties = {
      description = "Microsoft Foundry / Azure OpenAI"
      url         = "${var.foundry_endpoint}openai"
      protocol    = "http"
      resourceId  = "https://management.azure.com${var.foundry_account_id}"
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
      circuitBreaker = {
        rules = [{
          name = "foundry-429-breaker"
          failureCondition = {
            count            = 5
            errorReasons     = ["Server errors"]
            interval         = "PT1M"
            statusCodeRanges = [{ min = 429, max = 429 }]
          }
          tripDuration = "PT30S"
        }]
      }
    }
  }
  response_export_values = ["properties.url"]
}

# ---------------- Content Safety backend (conditional) ------------------
# Per Microsoft docs (llm-content-safety policy reference) and the official
# Azure-Samples/AI-Gateway/labs/content-safety/main.bicep sample, the backend
# MUST configure credentials.managedIdentity.resource = "https://cognitiveservices.azure.com"
# for the <llm-content-safety> policy to authenticate to /contentsafety/text:*.
# Without this credentials block, APIM forwards UNAUTHENTICATED requests and the
# backend returns 401 — surfaced to the caller as 403 ContentBlocked for ALL prompts
# (including benign), which we hit in the 2026-06-05 validation. APIM MI also needs
# "Cognitive Services User" role on the CS account (granted in foundry-rbac.tf for
# Foundry-bundled CS; required separately for a standalone CS resource).
resource "azapi_resource" "content_safety_backend" {
  count     = (var.enable_content_safety || var.enable_prompt_shields) ? 1 : 0
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  parent_id = azurerm_api_management.this.id
  name      = "content-safety-backend"
  # azapi provider schema doesn't yet expose credentials.managedIdentity for this
  # API version (mirrors Bicep BCP037). Disable per-resource schema validation —
  # the shape is verified against Microsoft's official AI-Gateway sample and the
  # llm-content-safety policy reference docs.
  schema_validation_enabled = false
  body = {
    properties = {
      description = "Azure AI Content Safety (Foundry-bundled or standalone)"
      # The <llm-content-safety> policy adds its own /contentsafety/text:* paths.
      # Trim trailing /contentsafety so caller can pass either-style endpoint.
      url        = replace(local.cs_endpoint, "/contentsafety", "")
      protocol   = "http"
      resourceId = "https://management.azure.com${local.cs_resource_id}"
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
      credentials = {
        managedIdentity = {
          resource = "https://cognitiveservices.azure.com"
        }
      }
    }
  }
}

# ---------------- Embeddings backend (conditional) ----------------------
resource "azapi_resource" "embeddings_backend" {
  count     = var.enable_semantic_cache ? 1 : 0
  type      = "Microsoft.ApiManagement/service/backends@2024-05-01"
  parent_id = azurerm_api_management.this.id
  name      = "embeddings-backend"
  body = {
    properties = {
      description = "Foundry embeddings deployment for APIM semantic cache."
      url         = "${var.foundry_endpoint}openai"
      protocol    = "http"
      resourceId  = "https://management.azure.com${var.foundry_account_id}"
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
    }
  }
}

# ---------------- Named values + external cache (conditional) -----------
resource "azurerm_api_management_named_value" "embeddings_deployment" {
  count               = var.enable_semantic_cache ? 1 : 0
  name                = "azure-openai-embeddings-deployment-name"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "azure-openai-embeddings-deployment-name"
  value               = var.embeddings_deployment_name
  secret              = false
}

resource "azurerm_api_management_named_value" "redis_conn" {
  count               = var.enable_semantic_cache ? 1 : 0
  name                = "redis-connection-string"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "redis-connection-string"
  value               = var.redis_connection_string
  secret              = true
}

# APIM external cache resource: azurerm provider doesn't expose this natively,
# use azapi. Cache name MUST be 'default' for the policy `cache-lookup-value`
# to pick it up implicitly.
resource "azapi_resource" "external_cache" {
  count     = var.enable_semantic_cache ? 1 : 0
  type      = "Microsoft.ApiManagement/service/caches@2024-05-01"
  parent_id = azurerm_api_management.this.id
  name      = "default"
  body = {
    properties = {
      description      = "Azure Managed Redis Enterprise — backing store for semantic cache"
      connectionString = var.redis_connection_string
      useFromLocation  = "default"
    }
  }
  depends_on = [azurerm_api_management_named_value.redis_conn]
}

# ---------------- AI API (OpenAI-compatible surface) --------------------
resource "azurerm_api_management_api" "foundry_openai" {
  name                  = "foundry-openai"
  api_management_name   = azurerm_api_management.this.name
  resource_group_name   = var.resource_group_name
  display_name          = "Foundry OpenAI"
  description           = "AI Gateway exposing Foundry models via MI-backed proxy."
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true
  service_url           = "${var.foundry_endpoint}openai"
  revision              = "1"
}

resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.foundry_openai.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/deployments/{deployment-id}/chat/completions"

  template_parameter {
    name     = "deployment-id"
    required = true
    type     = "string"
  }

  request {
    query_parameter {
      name          = "api-version"
      required      = true
      type          = "string"
      default_value = "2024-10-21"
    }
  }
}

# ---------------- API-level policy (assembled) --------------------------
resource "azurerm_api_management_api_policy" "foundry_openai" {
  api_name            = azurerm_api_management_api.foundry_openai.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  xml_content         = local.api_policy

  depends_on = [
    azapi_resource.foundry_backend,
    azapi_resource.content_safety_backend,
    azapi_resource.embeddings_backend,
    azapi_resource.external_cache,
    azurerm_api_management_named_value.embeddings_deployment,
  ]
}

# ---------------- Product + token-limit policy --------------------------
resource "azurerm_api_management_product" "foundry_default" {
  product_id            = "foundry-default"
  api_management_name   = azurerm_api_management.this.name
  resource_group_name   = var.resource_group_name
  display_name          = "Foundry Default"
  description           = "Default product for AI Gateway consumption (TPM cap parameterised)."
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "foundry_default" {
  product_id          = azurerm_api_management_product.foundry_default.product_id
  api_name            = azurerm_api_management_api.foundry_openai.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
}

resource "azurerm_api_management_product_policy" "foundry_default" {
  product_id          = azurerm_api_management_product.foundry_default.product_id
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  xml_content         = local.product_policy

  depends_on = [azurerm_api_management_product_api.foundry_default]
}

# ---------------- App Insights logger + diagnostics ---------------------
resource "azurerm_api_management_logger" "appi" {
  name                = "appi-logger"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  resource_id         = var.app_insights_id

  application_insights {
    instrumentation_key = regex("InstrumentationKey=([^;]+)", var.app_insights_conn_string)[0]
  }
}

resource "azurerm_api_management_diagnostic" "appi" {
  identifier                = "applicationinsights"
  resource_group_name       = var.resource_group_name
  api_management_name       = azurerm_api_management.this.name
  api_management_logger_id  = azurerm_api_management_logger.appi.id
  sampling_percentage       = 100
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "information"
  http_correlation_protocol = "W3C"

  frontend_request {
    headers_to_log = ["x-project", "x-use-case", "x-cost-center"]
  }
  backend_response {
    headers_to_log = ["x-ms-region"]
  }
}

# `azuremonitor` diagnostic: header capture for chargeback KQL.
# Created via azapi since azurerm's `azurerm_api_management_diagnostic`
# expects an `api_management_logger_id` (App Insights logger only).
resource "azapi_resource" "azuremonitor_diagnostic" {
  type      = "Microsoft.ApiManagement/service/diagnostics@2024-05-01"
  parent_id = azurerm_api_management.this.id
  name      = "azuremonitor"
  body = {
    properties = {
      loggerId    = "${azurerm_api_management.this.id}/loggers/azuremonitor"
      alwaysLog   = "allErrors"
      verbosity   = "information"
      logClientIp = true
      sampling = {
        samplingType = "fixed"
        percentage   = 100
      }
      frontend = {
        request = {
          headers = ["x-project", "x-use-case", "x-cost-center", "User-Agent"]
        }
        response = { headers = [] }
      }
      backend = {
        request  = { headers = [] }
        response = { headers = ["x-ms-region"] }
      }
    }
  }
  depends_on = [azurerm_monitor_diagnostic_setting.apim]
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "diag-apim"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = var.workspace_resource_id

  enabled_log { category = "GatewayLogs" }
  enabled_metric { category = "AllMetrics" }
}

# ---------------- RBAC: APIM SAMI → Foundry role pair -------------------
# Microsoft AI Gateway guidance assigns BOTH roles to the APIM MI:
#   - Cognitive Services User       (a97b65f3-...): base data-plane access
#   - Cognitive Services OpenAI User (5e0bd9bd-...): REQUIRED for /openai/*
#     (chat completions, embeddings). Without it APIM gets 401 from Foundry.
# Mirrors apim-foundry-rbac.bicep. skip_service_principal_aad_check=true
# avoids the AAD-replication race when SAMI was just created.
resource "azurerm_role_assignment" "apim_to_foundry" {
  count                            = var.enable_foundry_rbac ? 1 : 0
  scope                            = var.foundry_account_id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/a97b65f3-24c7-4388-baec-2e87135dc908"
  principal_id                     = azurerm_api_management.this.identity[0].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "apim_to_foundry_openai" {
  count                            = var.enable_foundry_rbac ? 1 : 0
  scope                            = var.foundry_account_id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
  principal_id                     = azurerm_api_management.this.identity[0].principal_id
  skip_service_principal_aad_check = true
}

data "azurerm_client_config" "current" {}

# ---------------- Outputs -----------------------------------------------
output "id" { value = azurerm_api_management.this.id }
output "name" { value = azurerm_api_management.this.name }
output "gateway_url" { value = azurerm_api_management.this.gateway_url }
output "principal_id" {
  value = length(azurerm_api_management.this.identity) > 0 ? azurerm_api_management.this.identity[0].principal_id : null
}
output "product_name" { value = azurerm_api_management_product.foundry_default.product_id }
output "api_name" { value = azurerm_api_management_api.foundry_openai.name }

