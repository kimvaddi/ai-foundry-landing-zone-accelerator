###############################################################################
# blueprint: smoke (Terraform)
#
# Cheapest deploy. Foundation (LAW + AppI + KV) + Foundry account + single
# model + standalone Search Basic. NO networking, NO PEs, NO compute.
#
# Use case: quickest CI smoke test. Cost ≈ $3-5/day. Deploy in <8 min.
###############################################################################

subscription_id = "REPLACE-WITH-YOUR-SUBSCRIPTION-GUID"
workload        = "klzfin"
environment     = "smoke"
location        = "eastus2"
search_location = "westus2"

network_mode = "standalone"

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
  env       = "smoke"
  blueprint = "smoke"
  purpose   = "ci-smoke"
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
    display_name = "Smoke project"
    description  = "Smoke-test Foundry project."
  }
]
