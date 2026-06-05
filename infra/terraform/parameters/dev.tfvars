###############################################################################
# dev.tfvars — Stage A cheap-standalone baseline (mirrors dev.bicepparam)
#
# Networking: standalone (we create our own private DNS zones + spoke VNet)
# Components: APIM off (saves ~$38/day), AI Search ON (~$0.10/hr Basic)
#
# Cost estimate (eastus2, 24h): ~$3-5
###############################################################################

subscription_id = "<REPLACE-WITH-SUBSCRIPTION-ID>"
workload        = "klzfin"
environment     = "dev"
location        = "eastus2"
search_location = "westus2"

# ----- Stage A networking -----
network_mode       = "standalone"
vnet_address_space = "10.50.0.0/20"

# ----- Component toggles (Stage A baseline) -----
components = {
  bastion = {
    deploy = false
    sku    = "Standard"
  }
  jumpvm = {
    deploy = false
    sku    = "Standard_B2s"
  }
  buildvm = {
    deploy = false
    sku    = "Standard_B2s"
  }
  app_gateway = {
    deploy      = false
    sku         = "WAF_v2"
    waf_enabled = true
  }
  container_apps_env = {
    deploy = false
  }
  apim = {
    deploy       = false
    sku          = "StandardV2"
    network_mode = "none"
  }
  standalone_search = {
    deploy = true
    sku    = "basic"
  }
  notifications = {
    deploy = false
  }
  otel_collector = {
    deploy = false
  }
}

tags = {
  workload   = "klzfin"
  env        = "dev"
  owner      = "platform-team"
  costCenter = "AI-Platform"
  purpose    = "stage-a-standalone-terraform"
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
    name         = "smoke"
    display_name = "Smoke validation project"
    description  = "Auto-created by klz-accelerator-finops Terraform dev deploy."
  }
]

# Sidestep stuck legacy RG with orphaned legionservicelink SAL
rg_suffix = "-v2"

