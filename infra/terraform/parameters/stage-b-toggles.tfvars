###############################################################################
# stage-b-toggles.tfvars — Exercises every Stage B toggle (mirrors
# stage-b-toggles.bicepparam)
#
# Enables:
#   • APIM with StandardV2 + VNet outbound integration ("external")
#   • Bastion + Jumpbox + BuildAgent
#   • AppGW WAF_v2
#   • Foundry agent injection
#   • BYOR connection to standalone Search (auto-wired)
#
# Disabled in eastus2 (AKS capacity headwinds):
#   • Container Apps Environment (containerAppsEnv) — re-enable in
#     a region with available AKS capacity.
#   • Foundry account capability host (kind=Agents) — same gating as CAE.
#
# Cost estimate (eastus2, 24h):
#   APIM StandardV2 + VNet: ~$38/day
#   AppGW WAF_v2:           ~$10/day
#   Bastion Standard:       ~$5/day
#   Two VMs (B2s each):     ~$2/day each
#   AI Search Basic:        ~$2.50/day
#   ≈ $60-65/day  ← tear down within 24h after validation.
#
# PRE-DEPLOY:
#   1. $env:KLZ_JUMPVM_PWD = "<strong-windows-password>"
#   2. $env:KLZ_BUILDVM_SSH_KEY = "<ssh-ed25519-public-key>"
#      terraform apply -var-file=parameters/stage-b-toggles.tfvars `
#                      -var "jumpvm_admin_password=$env:KLZ_JUMPVM_PWD" `
#                      -var "buildvm_ssh_public_key=$env:KLZ_BUILDVM_SSH_KEY"
###############################################################################

subscription_id = "<REPLACE-WITH-SUBSCRIPTION-ID>"
workload        = "klzfin"
environment     = "dev"
location        = "eastus2"
search_location = "westus2"

# ----- Networking (standalone for cheap validation) -----
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
  bastion            = { deploy = true, sku = "Standard" }
  jumpvm             = { deploy = true, sku = "Standard_B2s" }
  buildvm            = { deploy = true, sku = "Standard_B2s" }
  app_gateway        = { deploy = true, sku = "WAF_v2", waf_enabled = true }
  container_apps_env = { deploy = false }
  apim               = { deploy = true, sku = "StandardV2", network_mode = "external" }
  standalone_search  = { deploy = true, sku = "basic" }
  notifications      = { deploy = false }
  otel_collector     = { deploy = false }
}

container_apps_env_internal = true

tags = {
  workload   = "klzfin"
  env        = "dev"
  owner      = "platform-team"
  costCenter = "AI-Platform"
  managedBy  = "klz-accelerator-finops"
  purpose    = "stage-b-toggle-validation-terraform"
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
    description  = "Default project for Stage B agent + BYOR validation."
  },
  {
    name         = "agents"
    display_name = "Agents project"
    description  = "Project that hosts agents via the Standard Agent Service."
  }
]

# Agent Service network injection on the AIFoundrySubnet (always created).
enable_foundry_agent_injection = true

# Capability host (kind=Agents) at account level — required for agents to
# land on the injected network. DISABLED in eastus2 due to AKS capacity.
create_foundry_capability_host = false

# BYOR: wire the standalone Search service into the `default` project.
# Empty target is auto-filled by main.tf when auto_wire_search_connection = true.
foundry_byor_connections = [
  {
    project_name     = "default"
    name             = "standalone-search"
    category         = "CognitiveSearch"
    target           = ""
    auth_type        = "AAD"
    is_shared_to_all = true
  }
]

auto_wire_search_connection = true
