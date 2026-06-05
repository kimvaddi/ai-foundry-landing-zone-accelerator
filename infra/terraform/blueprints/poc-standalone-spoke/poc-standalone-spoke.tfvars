###############################################################################
# blueprint: poc-standalone-spoke (Terraform)
#
# Standalone networking (no hub, no firewall) + Foundry + Search + 21 PDNS
# zones + PEs. Compute toggles off. APIM off.
#
# Use case: quickest "real" deploy with private networking. Cost ≈ $5-8/day.
###############################################################################

subscription_id = "REPLACE-WITH-YOUR-SUBSCRIPTION-GUID"
workload        = "klzfin"
environment     = "poc"
location        = "eastus2"
search_location = "westus2"

network_mode       = "standalone"
vnet_address_space = "10.50.0.0/20"

components = {
  bastion            = { deploy = false }
  jumpvm             = { deploy = false }
  buildvm            = { deploy = false }
  app_gateway        = { deploy = false }
  container_apps_env = { deploy = false }
  apim               = { deploy = false }
  standalone_search  = { deploy = true, sku = "basic" }
  notifications      = { deploy = false }
  otel_collector     = { deploy = false }
}

tags = {
  workload  = "klzfin"
  env       = "poc"
  blueprint = "poc-standalone-spoke"
}

model_deployments = [
  {
    name  = "gpt-4o-mini"
    model = { format = "OpenAI", name = "gpt-4o-mini", version = "2024-07-18" }
    sku   = { name = "GlobalStandard", capacity = 10 }
  }
]

foundry_projects = [
  {
    name         = "default"
    display_name = "PoC project"
    description  = "PoC standalone-spoke Foundry project."
  }
]
