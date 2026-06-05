###############################################################################
# blueprint: prod-standalone-with-fw (Terraform) — DEFERRED
#
# Standalone-with-firewall mode (module owns the spoke FW + policy + 0/0 UDR).
# Full prod surface: Bastion + Jump + Build + AppGW + APIM internal + CAE.
#
# NOTE: standalone-with-firewall mode is currently DEFERRED in the engine
# (Stage A locked in standalone + hub-connected). This blueprint will become
# deployable once the firewall + UDR-attach two-pass deploy lands.
###############################################################################

subscription_id = "REPLACE-WITH-YOUR-SUBSCRIPTION-GUID"
workload        = "klzfin"
environment     = "prod"
location        = "eastus2"
search_location = "westus2"

network_mode       = "standalone-with-firewall"
vnet_address_space = "10.50.0.0/20"

apim_publisher = {
  local_part = "platform"
  domain     = "klzfin.com"
  name       = "KLZ FinOps Platform"
}

components = {
  bastion            = { deploy = true, sku = "Standard" }
  jumpvm             = { deploy = true, sku = "Standard_B2s" }
  buildvm            = { deploy = true, sku = "Standard_B2s" }
  app_gateway        = { deploy = true, sku = "WAF_v2", waf_enabled = true }
  container_apps_env = { deploy = true }
  apim               = { deploy = true, sku = "StandardV2", network_mode = "internal" }
  standalone_search  = { deploy = true, sku = "standard" }
  notifications      = { deploy = true }
  otel_collector     = { deploy = false }
}

tags = {
  workload  = "klzfin"
  env       = "prod"
  blueprint = "prod-standalone-with-fw"
}

model_deployments = [
  {
    name  = "gpt-4o"
    model = { format = "OpenAI", name = "gpt-4o", version = "2024-11-20" }
    sku   = { name = "GlobalStandard", capacity = 50 }
  },
  {
    name  = "text-embedding-3-large"
    model = { format = "OpenAI", name = "text-embedding-3-large", version = "1" }
    sku   = { name = "Standard", capacity = 10 }
  }
]

foundry_projects = [
  {
    name         = "platform"
    display_name = "Platform team"
    description  = "Foundry workspace for the central AI platform team."
  }
]

enable_foundry_agent_injection = true
create_foundry_capability_host = true

# AI Gateway safety + semantic cache (all 3 ON for prod baseline)
enable_content_safety          = true
enable_prompt_shields          = true
safety_threshold               = 4
enable_semantic_cache          = true
embeddings_deployment_name     = "text-embedding-3-large"
apim_product_tokens_per_minute = 100000
