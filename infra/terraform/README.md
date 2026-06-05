###############################################################################
# README — klz-accelerator-finops Terraform stack
#
# This is the Terraform parity tree for the Bicep stack under `infra/bicep/`.
# Both stacks are first-class deployment paths — pick one.
#
# Architecture (Option B from p6 plan):
#   • Foundry account + projects + BYOR + caphost
#       → Azure/avm-ptn-aiml-ai-foundry/azurerm  (~0.10)
#   • Hub greenfield  (network_mode = hub-greenfield)
#       → Azure/terraform-azurerm-avm-ptn-aiml-landing-zone  (~0.7)
#   • Everything else (spoke VNet, APIM, Bastion, AppGW, CAE, observability,
#     finops custom tables, private DNS) — thin custom modules under modules/
###############################################################################

# Quickstart (dev / smoke):

#   cd infra/terraform
#   az login
#   terraform init
#   terraform validate
#   terraform plan  -var-file=parameters/dev.tfvars -out=tfplan
#   terraform apply tfplan

# Teardown:

#   terraform destroy -var-file=parameters/dev.tfvars

# Layout:

#   .
#   ├── main.tf, variables.tf, locals.tf, outputs.tf, providers.tf, versions.tf
#   ├── modules/
#   │   ├── foundation/            LAW + AppI + KV
#   │   ├── spoke-network/         VNet + 9-subnet catalog + NSGs + delegations
#   │   ├── private-dns/           21 PDNS zones + spoke links
#   │   ├── hub-greenfield/        AVM ptn aiml-landing-zone wrapper
#   │   ├── foundry-stack/         AVM ptn aiml-ai-foundry + extra projects + BYOR + caphost
#   │   ├── ai-search/             Standalone Azure AI Search
#   │   ├── apim/                  API Management variable SKU + VNet mode
#   │   ├── compute/{bastion,jumpvm,build-agent,app-gateway,cae}/
#   │   ├── observability/         Alerts + workbook + scheduled query rule
#   │   └── finops/                DCE + DCR + custom LAW tables (Pricing/Quota/AgentAudit)
#   └── parameters/
#       ├── dev.tfvars                          Stage A standalone baseline (cheap)
#       ├── full.tfvars                         Standalone + APIM + components on
#       ├── stage-b-toggles.tfvars              Full surface (live-validation fixture)
#       └── enterprise-hub-connected.sample.tfvars   Hub-connected sample (placeholders)

# Toggles map (variables.tf → components):

#   bastion             { deploy, sku }
#   jumpvm              { deploy, sku }
#   buildvm             { deploy, sku }
#   app_gateway         { deploy, sku, waf_enabled }
#   container_apps_env  { deploy }
#   apim                { deploy, sku, network_mode }   network_mode = none|external|internal
#   standalone_search   { deploy, sku }
#   notifications       { deploy }
#   otel_collector      { deploy }

# Networking modes (var.network_mode):

#   standalone                — brand-new spoke VNet, no FW, no hub (DEFAULT)
#   standalone-with-firewall  — brand-new spoke VNet + AzureFirewallSubnet provisioned
#   hub-connected             — brand-new spoke VNet, peers to existing hub (BYO)
#   hub-greenfield            — brand-new hub via Azure/avm-ptn-aiml-landing-zone + brand-new spoke

# Parity contract with Bicep:

#   • Same resource group layout: rg-{workload}-platform-{env}, rg-{workload}-foundry-{env}
#   • Same name suffix algorithm (sha256(workload+env+sub)[:4])
#   • Same subnet catalog (alphabetical 9-subnet, identical CIDRs from cidrsubnet())
#   • Same 21 PDNS zone catalog (vaultcore, openai, search, etc.)
#   • Same toggle catalog
#   • Same effective output surface (account_endpoint, subnet_ids map, etc.)
