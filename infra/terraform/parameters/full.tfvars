###############################################################################
# full.tfvars — Stage A standalone landing zone with APIM (mirrors full.bicepparam)
#
# Networking: standalone (we create our own private DNS zones + spoke VNet)
# Components: APIM ON (StandardV2, PE-mode — no VNet injection yet), Search ON
#
# Cost estimate (eastus2, 24h): ~$45-50
#   APIM StandardV2: ~$38/day  ← biggest line item, tear down within 24h
#   AI Search Basic: ~$2.50/day
#   Everything else combined: ~$5/day
#
# Use case: validate full AI gateway pipeline (APIM → Foundry MI → token-limit
# + emit-metrics policy → App Insights customMetrics → workbook).
###############################################################################

subscription_id = "<REPLACE-WITH-SUBSCRIPTION-ID>"
workload        = "klzfin"
environment     = "dev"
location        = "eastus2"
search_location = "westus2"

# ----- Stage A networking -----
network_mode       = "standalone"
vnet_address_space = "10.50.0.0/20"

# ----- APIM publisher contact -----
apim_publisher = {
  local_part = "platform"
  domain     = "klzfin.com"
  name       = "KLZ FinOps Platform"
}

# ----- Component toggles -----
components = {
  bastion            = { deploy = false, sku = "Standard" }
  jumpvm             = { deploy = false, sku = "Standard_B2s" }
  buildvm            = { deploy = false, sku = "Standard_B2s" }
  app_gateway        = { deploy = false, sku = "WAF_v2", waf_enabled = true }
  container_apps_env = { deploy = false }
  apim               = { deploy = true, sku = "StandardV2", network_mode = "none" }
  standalone_search  = { deploy = true, sku = "basic" }
  notifications      = { deploy = false }
  otel_collector     = { deploy = false }
}

tags = {
  workload   = "klzfin"
  env        = "dev"
  owner      = "platform-team"
  costCenter = "AI-Platform"
  managedBy  = "klz-accelerator-finops"
  purpose    = "stage-a-full-standalone-terraform"
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
    display_name = "Default project"
    description  = "Auto-created by klz-accelerator-finops Terraform full deploy."
  }
]
