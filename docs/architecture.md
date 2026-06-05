# Target architecture

This document describes the architecture deployed by the **Azure AI Foundry Landing Zone + FinOps Accelerator**. It covers:

1. [Subscription + management group layout](#1-subscription--management-group-layout)
2. [Spoke logical view — standalone mode (greenfield)](#2-spoke-logical-view--standalone-mode-greenfield)
3. [Spoke logical view — hub-connected mode (brownfield)](#3-spoke-logical-view--hub-connected-mode-brownfield)
4. [Subnet catalog (9 subnets, 8 active by default)](#4-subnet-catalog)
5. [Dataflow — request lifecycle](#5-dataflow--request-lifecycle)
6. [Dataflow — observability + FinOps pipeline](#6-dataflow--observability--finops-pipeline)
7. [Trust boundaries](#7-trust-boundaries)
8. [Cross-stack parity (Bicep ↔ Terraform)](#8-cross-stack-parity-bicep--terraform)

---

## 1. Subscription + management group layout

The accelerator is **subscription-scoped** — it deploys into a single subscription. You bring the management-group layout. A typical enterprise pattern:

```mermaid
flowchart TB
  subgraph tenant["Entra ID Tenant"]
    subgraph mgRoot["Tenant Root Group"]
      subgraph mgPlatform["MG: Platform"]
        subgraph subConn["SUB: Connectivity (BYO hub)"]
          HubVnet[Hub VNet]
          HubFW[Azure Firewall]
          HubDNS[Central PDNS Zones]
        end
        subgraph subMgmt["SUB: Management (LAW + AppI)"]
          CentralLAW[Optional central LAW]
        end
      end
      subgraph mgLandingZones["MG: Landing Zones"]
        subgraph mgCorp["MG: Corp"]
          subgraph subDev["SUB: AI-Dev (THIS ACCELERATOR)"]
            spokeDev[Spoke VNet + Foundry stack]
          end
          subgraph subProd["SUB: AI-Prod (THIS ACCELERATOR, env=prod)"]
            spokeProd[Spoke VNet + Foundry stack]
          end
        end
      end
    end
  end
  spokeDev <-.peering + UDR.-> HubVnet
  spokeProd <-.peering + UDR.-> HubVnet
  HubDNS -.linked to spoke VNets.-> spokeDev
  HubDNS -.linked to spoke VNets.-> spokeProd
```

| MG | Subscription | Role |
|---|---|---|
| `Platform` → Connectivity | `SUB-CONN` (BYO) | Hub VNet, Firewall, central Private DNS Zones |
| `Platform` → Management | `SUB-MGMT` (optional) | Central LAW if you aggregate cross-spoke logs |
| `Landing Zones` → Corp | `SUB-AI-DEV` | This accelerator's `env=dev` deploy |
| `Landing Zones` → Corp | `SUB-AI-PROD` | This accelerator's `env=prod` twin |

The accelerator's role assignments are scoped to the **target RGs only** (`rg-{workload}-platform-{env}`, `rg-{workload}-foundry-{env}`) — it does not require Owner at MG scope.

---

## 2. Spoke logical view — standalone mode (greenfield)

`networkMode = 'standalone'` — the accelerator creates everything end-to-end. No hub required.

```mermaid
flowchart TB
  subgraph subSpoke["Subscription (target sub)"]
    subgraph rgPlatform["RG: rg-{workload}-platform-{env}"]
      LAW[Log Analytics<br/>Workspace<br/>+ 3 custom tables]
      AppI[Application Insights<br/>workspace-based<br/>DisableLocalAuth: true]
      KV[Key Vault<br/>RBAC + purge-protect<br/>Firewall: Deny + AzureServices bypass]
      Spoke[Spoke VNet<br/>10.50.0.0/20<br/>9-subnet catalog]
      PDNS[21 Private DNS Zones<br/>created in-spoke]
      DCE[Data Collection<br/>Endpoint + Rules]
      Workbooks[Workbooks: FinOps<br/>+ Agent Perf + Safety<br/>+ Alerts/SQR]
      OPT_APIM[APIM<br/>StandardV2/Premium<br/>VNet-injected or PE<br/>AI Gateway policies]:::optional
      OPT_AppGW[App Gateway<br/>WAF_v2 OWASP 3.2]:::optional
      OPT_CAE[Container Apps Env<br/>VNet-injected]:::optional
      OPT_Bastion[Azure Bastion]:::optional
      OPT_JumpVM[Jumpbox VM<br/>Windows]:::optional
      OPT_BuildVM[Build agent VM<br/>Linux]:::optional
      OPT_ActionGrp[Action Group<br/>+ Logic App<br/>Teams + email]:::optional
    end
    subgraph rgFoundry["RG: rg-{workload}-foundry-{env}"]
      Foundry[Foundry Account<br/>AIServices kind<br/>MI + disableLocalAuth: true<br/>publicNetworkAccess: Disabled]
      Proj1[Project: smoke]
      Proj2[Project: chat]:::optional
      Model1[Model deployment<br/>gpt-4o-mini]
      Search[AI Search<br/>Basic SKU<br/>MI auth]
      OPT_BYOR[BYOR connections<br/>Cosmos / Storage / KV]:::optional
      Foundry --> Proj1
      Foundry --> Proj2
      Foundry --> Model1
      Proj1 -.connection.-> Search
      Proj1 -.connection.-> OPT_BYOR
    end
    PE_F[PE: Foundry → cognitiveservices + openai]
    PE_KV[PE: KV → vaultcore]
    PE_S[PE: Search → search]:::optional
    PE_F --> Foundry
    PE_KV --> KV
    PE_S --> Search
    PDNS -.A-record.-> PE_F
    PDNS -.A-record.-> PE_KV
    PDNS -.A-record.-> PE_S
  end
  Client[Client app / agent runtime] --> OPT_AppGW
  OPT_AppGW --> OPT_APIM
  Client -.direct.-> OPT_APIM
  OPT_APIM -->|MI auth| Foundry
  Foundry --> LAW
  OPT_APIM --> LAW
  Search --> LAW
  KV --> LAW

  classDef optional fill:#fef3c7,stroke:#f59e0b,stroke-dasharray:5,color:#000
```

**Legend:** dashed/amber boxes are gated by `components.*.deploy` toggles; solid boxes deploy unconditionally.

---

## 3. Spoke logical view — hub-connected mode (brownfield)

`networkMode = 'hub-connected'` — the spoke peers into your existing ALZ hub, skips PDNS creation in favor of linking to your central zones, and (optionally) sends `0/0` through your hub firewall.

```mermaid
flowchart LR
  subgraph subHub["SUB: Connectivity (BYO hub — you own)"]
    HubVnet[Hub VNet]
    HubFW[Azure Firewall<br/>private IP = hubFirewallPrivateIp]
    HubDNS[Central Private DNS Zones<br/>passed via existingPrivateDnsZones]
    Bastion_Hub[Hub Bastion<br/>optional]
  end
  subgraph subSpoke["SUB: AI Spoke (this accelerator)"]
    SpokeVnet[Spoke VNet<br/>10.50.0.0/20]
    PE_Subnet[PrivateEndpointSubnet<br/>10.50.0.0/24]
    AIF_Subnet[AIFoundrySubnet<br/>10.50.1.0/24<br/>delegated Microsoft.App/environments]
    UDR[Route Table<br/>0.0.0.0/0 → hub FW IP]
    FoundryPE[Foundry PE]
    KVPE[KV PE]
  end
  SpokeVnet <-->|peering<br/>created by accelerator| HubVnet
  SpokeVnet -.optional reverse peer.-> HubVnet
  HubDNS -.linked to spoke VNet<br/>by accelerator.-> SpokeVnet
  AIF_Subnet -.UDR attached.-> UDR
  UDR -.next hop.-> HubFW
  HubFW -.allowlist FQDNs.-> Internet[(Internet / SaaS)]
  PE_Subnet -.hosts.-> FoundryPE
  PE_Subnet -.hosts.-> KVPE
```

**Inputs the spoke owner provides:**

| Param | How to get it |
|---|---|
| `hubVnetResourceId` | `az network vnet show -g <hub-rg> -n <hub-vnet> --query id -o tsv` |
| `hubFirewallPrivateIp` | `az network firewall ip-config list -g <hub-rg> --firewall-name <fw> --query "[0].privateIpAddress" -o tsv` |
| `existingPrivateDnsZones` | Map of `<zone-name>` → `<resource-id>` for each PDNS zone in your hub. The accelerator creates a VNet link from spoke to each. |
| `enableForcedTunneling` | `true` (default) — creates the `0/0` UDR; set to `false` if your hub doesn't gate egress |
| `createReverseHubPeer` | `false` (default) — set to `true` only if the spoke principal has write rights on the hub VNet |

See [hub-spoke-integration.md](hub-spoke-integration.md) for the wiring runbook.

---

## 4. Subnet catalog

The 9-subnet catalog is **always allocated in address space**, but each subnet is **only created if its `components.<name>.deploy` toggle is true** (or it's an "always-on" subnet). This means you can land new compute later without re-IPing.

| # | Subnet | `components` toggle | Prefix | CIDR @ `10.50.0.0/20` | Purpose |
|---|---|---|---|---|---|
| 1 | `PrivateEndpointSubnet` | always on | /24 | `10.50.0.0/24` | All PE NICs land here |
| 2 | `AIFoundrySubnet` | always on (delegated `Microsoft.App/environments`) | /24 | `10.50.1.0/24` | Foundry agent VNet injection target |
| 3 | `ContainerAppEnvironmentSubnet` | `containerAppsEnv.deploy` | /23 | `10.50.2.0/23` | CAE workload subnet (needs `/23` minimum) |
| 4 | `AppGatewaySubnet` | `appGateway.deploy` | /24 | `10.50.4.0/24` | AppGW WAF_v2 |
| 5 | `APIMSubnet` | `apim.deploy` + VNet mode | /26 | `10.50.5.0/26` | APIM VNet injection (external or internal) |
| 6 | `DevOpsBuildSubnet` | `buildvm.deploy` | /26 | `10.50.5.64/26` | Linux build agent |
| 7 | `JumpboxSubnet` | `jumpvm.deploy` | /26 | `10.50.5.128/26` | Windows ops jumpbox |
| 8 | `AzureBastionSubnet` | `bastion.deploy` | /26 | `10.50.5.192/26` | Bastion (subnet name is mandatory) |
| 9 | `AzureFirewallSubnet` | reserved (greenfield hub blueprint = P9 carryover) | /26 | `10.50.6.0/26` | Reserved for future standalone-with-firewall mode |

**Notes:**
- `AIFoundrySubnet` is created with `Microsoft.App/environments` delegation regardless of whether CAE is enabled — Foundry agent VNet injection needs the delegation marker.
- `APIMSubnet` is only created when APIM is deployed *and* the network mode is VNet (`external` or `internal`). For PE-mode APIM, no subnet is consumed in this slot.
- `AzureBastionSubnet` is the only subnet name dictated by Azure (Bastion service requires this exact name); the other 8 are convention.
- The two `/24`s for PE and AIFoundry are sized for ~250 endpoints each — typical enterprise scale is well under that.
- Address space is **fully allocated even if subnets are off** to prevent re-IP when toggles flip on later.

---

## 5. Dataflow — request lifecycle

Below: a client app calls an agent that uses **two tools (Fabric query + AI Search)** and a **GPT model**, with APIM AI Gateway in front.

```mermaid
sequenceDiagram
  autonumber
  participant Client as Client app / agent runtime
  participant AppGW as App Gateway (WAF v2)
  participant APIM as APIM AI Gateway
  participant Foundry as Foundry Agent
  participant Fabric as Tool: Fabric query
  participant Search as Tool: AI Search
  participant Model as Model deployment

  Client->>AppGW: POST /chat (traceparent header)
  AppGW->>APIM: forward (after WAF inspection)
  Note over APIM: policy: validate-jwt<br/>token-limit (per project)<br/>prompt-shields<br/>content-safety<br/>semantic-cache lookup
  alt cache hit
    APIM-->>Client: cached response
  else cache miss
    APIM->>Foundry: route (MI auth — no key)
    Foundry->>Fabric: tool span: fabric.query
    Fabric-->>Foundry: rows
    Foundry->>Search: tool span: search.query
    Search-->>Foundry: chunks
    Foundry->>Model: gen_ai.completion
    Model-->>Foundry: tokens
    Foundry-->>APIM: response + usage
    Note over APIM: policy: emit-token-metric<br/>(Project, UseCase, CostCenter dimensions)<br/>content-safety on response
    APIM-->>Client: response
  end
  Note over APIM: All spans + metrics flow to App Insights → Agent Performance workbook
```

**Why this matters:**
- The `emit-token-metric` policy attaches **per-request dimensions** (`Project`, `UseCase`, `CostCenter`) so the FinOps workbook can break burn down by team without sampling Cost Management.
- `semantic-cache` (Azure Redis Enterprise via vector index) cuts repeat-query cost ~30-60% depending on workload.
- `prompt-shields` + `content-safety` give you the "Microsoft Azure AI Content Safety" enterprise SLAs end-to-end.
- The agent's per-tool spans (Fabric, Search, Model) are visible separately in the workbook — when latency is bad you immediately know if it's the network, Fabric, Search, or the model itself.

---

## 6. Dataflow — observability + FinOps pipeline

```mermaid
flowchart LR
  Foundry[Foundry Account<br/>+ Projects + Models]
  APIM[APIM AI Gateway]
  Search[AI Search]
  KV[Key Vault]
  VNet[Spoke VNet + NSGs]
  AppGW[App Gateway]

  Foundry -->|diag settings| LAW
  APIM -->|diag settings + emit-metric| LAW
  Search -->|diag settings| LAW
  KV -->|diag settings| LAW
  VNet -->|diag settings| LAW
  AppGW -->|diag settings| LAW

  subgraph LAW["Log Analytics Workspace"]
    Stock[Stock tables<br/>AzureMetrics, AzureDiagnostics]
    Custom1[AiUsage_CL<br/>per-request tokens + dims]
    Custom2[AiCost_CL<br/>computed cost rows]
    Custom3[AiAgentSpan_CL<br/>per-tool OTel spans]
    DCR1[DCR: AI usage routing]
    DCR2[DCR: cost calc]
    DCR3[DCR: agent spans]
    DCR1 --> Custom1
    DCR2 --> Custom2
    DCR3 --> Custom3
  end

  Custom1 --> WB_FinOps[Workbook:<br/>FinOps Showback<br/>by Project/CostCenter/UseCase]
  Custom2 --> WB_FinOps
  Custom3 --> WB_AgentPerf[Workbook:<br/>Agent Performance<br/>p50/p95/p99 per tool span]
  Stock --> WB_Health[Workbook:<br/>Foundry Health]
  Stock --> WB_Safety[Workbook:<br/>Content Safety]

  WB_FinOps --> SQR1[Scheduled Query Rule:<br/>budget threshold]
  SQR1 -->|fires| ActionGroup[Action Group]
  ActionGroup --> Teams[Teams webhook]
  ActionGroup --> Email[Email list]
  ActionGroup --> LogicApp[Logic App:<br/>auto-suspend APIM subscription]
  LogicApp --> APIM

  OTel[OTel Collector<br/>GenAI semantic conventions] -.optional.-> AppI[Application Insights]
  AppI --> WB_AgentPerf
```

**Key design choices:**
- **Custom LA tables** (`*_CL`) drive per-project cost lineage — far cheaper than streaming raw Cost Management exports.
- **DCRs route metrics** from APIM's `emit-token-metric` policy directly into the custom tables.
- **Workbooks query LAW** (not Cost Management) — fast, no API throttling.
- **Auto-suspend Logic App** is opt-in (`components.notifications.deploy = true`) and idempotent — it disables the offending APIM subscription, not the whole gateway.
- **OTel collector** is also opt-in — you wire your existing collector to ship spans to AppI; the workbook works either way.

---

## 7. Trust boundaries

| Boundary | Defense |
|---|---|
| **Internet → Spoke** | App Gateway WAF_v2 OWASP 3.2 in Prevention mode (when `appGateway.deploy=true`) |
| **App → APIM** | OAuth/JWT validation via APIM policy; per-subscription rate limit; token-limit policy |
| **APIM → Foundry** | Managed identity, MI granted `Cognitive Services User` at Foundry account scope; `disableLocalAuth=true` blocks API-key fallback |
| **App → Storage/KV/Search direct** | Blocked by `publicNetworkAccess=Disabled` on Foundry + Search + KV firewall Deny; resolved only via in-spoke Private Endpoints |
| **Spoke → Internet** | If `hub-connected`: forced through hub firewall via `0/0` UDR. If `standalone`: no egress control (POC posture) |
| **Operator → Spoke** | Bastion + Jumpbox (when toggled on); no public RDP/SSH |
| **Data-plane CMEK** | KV holds CMK keys; Foundry encryption with CMK is opt-in (P9: not yet wired in either stack) |
| **Identity** | All MIs assigned via accelerator; no service principals with client secrets are created |
| **Policy** | The 12-control initiative under `policy/` audits all of the above continuously |

---

## 8. Cross-stack parity (Bicep ↔ Terraform)

Both stacks deploy the **same architecture**. The CI parity test (`scripts/parity-diff.ps1`) asserts the resource graphs match within a documented allowlist. The current systemic asymmetries:

| Type | TF − Bicep | Why |
|---|---|---|
| `Microsoft.Insights/actionGroups` | **+1** | TF always creates an AG; Bicep gates behind `notifications.deploy` |
| `Microsoft.Insights/dataCollectionRules` | **−2** | TF ports only 1 of 3 FinOps DCRs (P9 carryover) |
| `Microsoft.Insights/diagnosticSettings` | **−5** | Bicep applies diag on KV + 2 NSGs + VNet + Search; TF only on Foundry (P9 carryover) |
| `Microsoft.Insights/workbooks` | **−1** | Bicep has FinOps + Agent Perf; TF has FinOps only (P9 carryover) |
| `Microsoft.Network/privateEndpoints` | **−1** | TF skips KV PE in smoke posture |
| `Microsoft.Network/privateEndpoints/privateDnsZoneGroups` | **−2** | TF inlines `private_dns_zone_group{}` in `azurerm_private_endpoint`; Bicep emits a child resource. Same runtime behavior, different ARM shape. |

All of these are tracked in [`docs/lint-baseline.md`](lint-baseline.md) and [`docs/parity-allowlist.json`](parity-allowlist.json). When the P9 carryover work lands, the TF stack will close the diff.

---

## Implementation notes

- **`cidrSubnet(network, newCIDR, idx)`** — `newCIDR` is the **absolute new prefix length** (24 → `/24`), not bits-to-add. Got this wrong twice during initial bring-up; live deploy was the only thing that caught it (`az deployment sub validate` skips nested-module expansion when the parent uses runtime references).
- **AVM modules** — Foundry stack uses [`Azure/avm-ptn-aiml-foundry-account`](https://registry.terraform.io/modules/Azure/avm-ptn-aiml-foundry-account/azurerm/latest) in Terraform; Bicep uses native resources + AVM where coverage exists.
- **Subscription scope** — `main.bicep` and `infra/terraform/main.tf` both deploy at **subscription scope**. They create the 2 RGs themselves. Don't pre-create them.
- **Region pinning** — search defaults to `westus2` (Basic SKU capacity in `eastus2` is constrained); APIM and everything else defaults to `eastus2`. Override via `location` + `searchLocation` parameters.
