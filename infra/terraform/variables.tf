###############################################################################
# klz-accelerator-finops — Terraform parity (p6)
#
# Variable surface mirrors infra/bicep/main.bicep top-level params 1:1 where it
# makes sense; some Bicep helper params are folded into nested var objects
# (e.g. apim publisher fields) to follow Terraform idioms.
#
# Naming maps:
#   workload       → var.workload
#   env            → var.environment
#   location       → var.location
#   tags           → var.tags
#   components     → var.components (object with sub-toggles)
#   networkMode    → var.network_mode
#   ...
###############################################################################

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID to deploy into."
}

variable "workload" {
  type        = string
  default     = "klzfin"
  description = "Workload short name (3-10 chars, lowercase alphanumerics)."

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.workload))
    error_message = "workload must be 3-10 lowercase alphanumerics."
  }
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment short name (dev/test/prod)."
}

variable "location" {
  type        = string
  default     = "eastus2"
  description = "Primary Azure region."
}

variable "search_location" {
  type        = string
  default     = null
  description = "Optional region override for the standalone AI Search service (eastus2 capacity is tight; westus2 is reliable). Falls back to var.location when null."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource."
}

variable "rg_suffix" {
  type        = string
  default     = ""
  description = "Optional suffix appended to resource group names (e.g., \"-v2\") to sidestep stuck/leftover RGs in shared sandboxes."
}

# ----- Networking -----

variable "network_mode" {
  type        = string
  default     = "standalone"
  description = "One of: standalone | standalone-with-firewall | hub-connected | hub-greenfield. Mirrors Bicep networkMode."

  validation {
    condition     = contains(["standalone", "standalone-with-firewall", "hub-connected", "hub-greenfield"], var.network_mode)
    error_message = "network_mode must be standalone | standalone-with-firewall | hub-connected | hub-greenfield."
  }
}

variable "vnet_address_space" {
  type        = string
  default     = "10.50.0.0/20"
  description = "Spoke VNet CIDR (must fit 9 subnets; /20 leaves growth room)."
}

# Used when network_mode = hub-connected; consumed by module.hub_peering.
variable "hub_vnet_resource_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Resource ID of an existing hub VNet (only used when network_mode = hub-connected).

    When set with network_mode = hub-connected, module.hub_peering creates the
    spoke->hub VNet peering. Pair with var.create_reverse_hub_peer = true to
    create the reverse hub->spoke peer (same subscription only).
  EOT
}

# Used when network_mode = hub-connected AND enable_forced_tunneling = true; consumed by module.route_table.
variable "hub_firewall_private_ip" {
  type        = string
  default     = ""
  description = <<-EOT
    Private IP of the existing hub firewall (only used when network_mode = hub-connected and UDRs are enabled).

    Becomes the VirtualAppliance next-hop on the 0.0.0.0/0 forced-tunnel route
    attached to AIFoundrySubnet + each toggle-gated workload subnet.
  EOT
}

# Used when network_mode = hub-connected; consumed by module.route_table.
variable "enable_forced_tunneling" {
  type        = bool
  default     = true
  description = <<-EOT
    When true and network_mode = hub-connected, install UDRs that route 0.0.0.0/0 to var.hub_firewall_private_ip.

    Per-subnet attach rules mirror Bicep main.bicep:udrCandidateSubnets:
    always AIFoundrySubnet; toggle-gated APIMSubnet, AppGatewaySubnet,
    ContainerAppEnvironmentSubnet, DevOpsBuildSubnet, JumpboxSubnet; never
    PrivateEndpointSubnet, AzureBastionSubnet, AzureFirewallSubnet.
  EOT
}

# Used when network_mode = hub-connected; consumed by module.hub_peering.
variable "create_reverse_hub_peer" {
  type        = bool
  default     = false
  description = <<-EOT
    When true and network_mode = hub-connected, create the hub-side peering back to the spoke (requires Network Contributor on hub).

    Only honored when the hub VNet is in the SAME subscription as the spoke
    (parity with Bicep — cross-sub reverse peer is deferred).
  EOT
}

variable "existing_private_dns_zones" {
  type        = map(string)
  default     = {}
  description = "Map of { zone_fqdn = existing_zone_resource_id } to reuse existing PDNS zones (typically supplied by hub). Zones not in this map are created in-spoke when network_mode != hub-connected."
}

# ----- Components catalog (mirrors Bicep `components` object) -----

variable "components" {
  type = object({
    bastion = optional(object({
      deploy = optional(bool, false)
      sku    = optional(string, "Standard")
    }), {})
    jumpvm = optional(object({
      deploy = optional(bool, false)
      sku    = optional(string, "Standard_B2s")
    }), {})
    buildvm = optional(object({
      deploy = optional(bool, false)
      sku    = optional(string, "Standard_B2s")
    }), {})
    app_gateway = optional(object({
      deploy      = optional(bool, false)
      sku         = optional(string, "WAF_v2")
      waf_enabled = optional(bool, true)
    }), {})
    container_apps_env = optional(object({
      deploy = optional(bool, false)
    }), {})
    apim = optional(object({
      deploy       = optional(bool, false)
      sku          = optional(string, "StandardV2")
      network_mode = optional(string, "none")
    }), {})
    standalone_search = optional(object({
      deploy = optional(bool, true)
      sku    = optional(string, "basic")
    }), {})
    notifications = optional(object({
      deploy = optional(bool, false)
    }), {})
    otel_collector = optional(object({
      deploy = optional(bool, false)
    }), {})
  })
  default     = {}
  description = "Toggle catalog — each sub-object controls whether the corresponding stack is deployed (and its SKU / mode)."
}

# ----- AI model deployments (passed through to AVM Foundry ptn) -----

variable "model_deployments" {
  type = list(object({
    name = string
    model = object({
      format  = string
      name    = string
      version = string
    })
    sku = object({
      name     = string
      capacity = number
    })
  }))
  default = [
    {
      name  = "gpt-4o-mini"
      model = { format = "OpenAI", name = "gpt-4o-mini", version = "2024-07-18" }
      sku   = { name = "GlobalStandard", capacity = 10 }
    }
  ]
  description = "AI model deployments to create on the Foundry account."
}

# ----- Foundry projects + BYOR -----

variable "foundry_projects" {
  type = list(object({
    name         = string
    display_name = string
    description  = string
  }))
  default = [
    {
      name         = "default"
      display_name = "Default project"
      description  = "Default Foundry project."
    }
  ]
  description = "Foundry projects to create under the account."
}

variable "foundry_byor_connections" {
  type = list(object({
    project_name     = string
    name             = string
    category         = string
    target           = optional(string, "")
    auth_type        = optional(string, "AAD")
    is_shared_to_all = optional(bool, true)
    metadata         = optional(map(string), {})
  }))
  default     = []
  description = "Per-project BYOR connections. Empty target on CognitiveSearch connections auto-fills to the standalone search endpoint when auto_wire_search_connection = true."
}

variable "enable_foundry_agent_injection" {
  type        = bool
  default     = false
  description = "When true, register the AIFoundrySubnet as the account-level networkInjections agent subnet."
}

variable "create_foundry_capability_host" {
  type        = bool
  default     = false
  description = "When true, create an account-level capabilityHost (kind=Agents). Disabled by default in eastus2 due to AKS capacity issues."
}

variable "auto_wire_search_connection" {
  type        = bool
  default     = true
  description = "When true, BYOR CognitiveSearch connections with empty target are filled to the standalone Search endpoint."
}

# ----- Notifications -----
# NOTE: declared for Bicep parity. P9 carryover work will pipe these into
# modules/observability/notifications (see docs/lint-baseline.md).

# tflint-ignore: terraform_unused_declarations
# P9 carryover: notifications module wiring not yet plumbed through main.tf.
variable "deploy_notifications" {
  type        = bool
  default     = false
  description = "Deploy the notifications module (Action Group + optional Logic App for Teams). P9 carryover."
}

# tflint-ignore: terraform_unused_declarations
# P9 carryover.
variable "enable_notifications_logic_app" {
  type        = bool
  default     = false
  description = "Enable the Logic App component of the notifications module. P9 carryover."
}

# tflint-ignore: terraform_unused_declarations
# P9 carryover.
variable "teams_webhook_url" {
  type        = string
  default     = ""
  description = "Teams incoming webhook URL for notifications Logic App. P9 carryover."
  sensitive   = true
}

# tflint-ignore: terraform_unused_declarations
# P9 carryover.
variable "notification_emails" {
  type        = string
  default     = ""
  description = "Comma-separated list of email addresses for the notifications Action Group. P9 carryover."
}

# ----- OTel collector -----
# NOTE: declared for Bicep parity. P9 carryover work will pipe this into
# modules/observability/otel-collector (see docs/lint-baseline.md).

# tflint-ignore: terraform_unused_declarations
# P9 carryover: otel-collector module wiring not yet plumbed through main.tf.
variable "otel_secondary_endpoint" {
  type        = string
  default     = ""
  description = "Optional secondary OTLP endpoint for the OTel collector to mirror traffic to (e.g. Datadog, Honeycomb). P9 carryover."
}

# ----- Compute creds -----

variable "jumpvm_admin_password" {
  type        = string
  default     = ""
  description = "Windows admin password for the jump VM (>=12 chars, complexity rules). Required when components.jumpvm.deploy = true."
  sensitive   = true
}

variable "buildvm_ssh_public_key" {
  type        = string
  default     = ""
  description = "ssh-ed25519 / ssh-rsa public key for the Linux build agent. Required when components.buildvm.deploy = true."
}

variable "container_apps_env_internal" {
  type        = bool
  default     = true
  description = "When true, deploy the Container Apps Environment in internal-only mode (VNet-injected)."
}

# ----- APIM publisher -----

variable "apim_publisher" {
  type = object({
    local_part = optional(string, "platform")
    domain     = optional(string, "klzfin.com")
    name       = optional(string, "KLZ FinOps Platform")
  })
  default     = {}
  description = "APIM publisher contact (local_part@domain, display name)."
}


# ----- Chokepoint -----

variable "enforce_apim_chokepoint" {
  type        = bool
  default     = false
  description = "When true, APIM AI Gateway becomes the single chokepoint for Foundry/Search/KV data-plane traffic. Flips Foundry+Search public_network_access to false, enables NSG enforcement on the PrivateEndpointSubnet, only APIMSubnet (+ exceptions) can reach the PEs. Requires components.apim.deploy=true AND components.apim.network_mode in {external,internal}."
}

variable "allow_cae_bypass" {
  type        = bool
  default     = false
  description = "When chokepoint is on, also allow ContainerAppEnvironmentSubnet -> PE inbound."
}

variable "allow_agent_subnet_bypass" {
  type        = bool
  default     = true
  description = "When chokepoint is on AND agent injection is on, allow AIFoundrySubnet -> PE inbound (required for the Standard Agent Service)."
}

###############################################################################
# AI Gateway safety + semantic-cache toggles (parity with Bicep main.bicep)
###############################################################################

variable "enable_content_safety" {
  type        = bool
  default     = false
  description = "Enable Azure AI Content Safety category scoring on APIM AI API."
}

variable "enable_prompt_shields" {
  type        = bool
  default     = false
  description = "Enable Prompt Shields jailbreak detection. Combined into the same llm-content-safety element as enable_content_safety."
}

variable "safety_threshold" {
  type        = number
  default     = 4
  description = "Content Safety severity threshold (FourSeverityLevels: 0/2/4/6). 4 = block medium+ severity."

  validation {
    condition     = contains([0, 2, 4, 6], var.safety_threshold)
    error_message = "safety_threshold must be 0, 2, 4, or 6."
  }
}

variable "enable_semantic_cache" {
  type        = bool
  default     = false
  description = "Enable APIM semantic cache (vector-similarity prompt match). Provisions Redis Enterprise + APIM external cache + embeddings backend."
}

variable "embeddings_deployment_name" {
  type        = string
  default     = "text-embedding-3-large"
  description = "Embedding deployment name used by the semantic cache lookup policy. Must exist on the Foundry account."
}

variable "apim_product_tokens_per_minute" {
  type        = number
  default     = 50000
  description = "Per-product TPM cap for the APIM `foundry-default` product. Templated into product-token-limit.xml."
}

###############################################################################
# Post-deploy RBAC (opt-in) — mirrors Bicep modules/security/rbac-*-scope.bicep
###############################################################################

variable "enable_post_deploy_rbac" {
  type        = bool
  default     = false
  description = "Master switch for the post-deploy RBAC modules. When false (default), no role assignments are emitted regardless of the object IDs below."
}

variable "foundry_admin_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry Owner on the Foundry account. Highly privileged. Leave empty to skip."
}

variable "foundry_lead_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry Project Manager on the Foundry account (team leads who publish agents and create projects). Leave empty to skip."
}

variable "foundry_developer_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Foundry User on the Foundry account (developers who build agents and call models). Leave empty to skip."
}

variable "platform_reader_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Reader on the platform RG (auditors / SREs / FinOps). Leave empty to skip."
}

variable "foundry_reader_group_object_id" {
  type        = string
  default     = ""
  description = "Entra group object ID -> Reader on the Foundry account. Leave empty to reuse var.platform_reader_group_object_id for backward compatibility with Bicep behavior."
}

variable "deployment_spn_object_id" {
  type        = string
  default     = ""
  description = "Service principal object ID -> Contributor on the platform RG (CI/CD pipelines that deploy workloads). Leave empty to skip."
}

###############################################################################
# Observability — alert toggles
###############################################################################

variable "deploy_cost_alert" {
  type        = bool
  default     = false
  description = "Deploy the cost-vs-quota scheduled query alert. Requires APIM + AI Gateway logging (ApiManagementGatewayLlmLog table) to exist; smoke blueprint leaves it off because the LAW table only appears after the first APIM AI request."
}

