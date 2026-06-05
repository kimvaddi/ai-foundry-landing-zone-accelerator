# Foundry Enterprise Readiness — What this accelerator implements

> Scope: A dev landing zone (e.g. `RG-DEV-AI`), mapped to the Microsoft **AI / Foundry Landing Zone Accelerator** + WAF-for-AI guidance.
> Target: A half-day enablement workshop covering landing zone + guardrails + observability + Defender + promote-to-prod.

---

## 1. Landing-zone readiness — required enterprise configuration

The Foundry account is easy to create, but the *platform* around it isn't enterprise-ready out of the box. These are the LZ "must-haves":

| # | Capability | Required configuration | Typical brownfield state |
|---|---|---|---|
| 1.1 | **Account topology** | One Foundry **account** per environment (dev/test/prod) under the matching CAF MG; **projects** map to use cases/teams (`proj-knowledge-search-dev` pattern is correct). Use **Standard SKU** with **CMK encryption**. | ✅ Account + a couple projects in dev. ❌ No prod twin yet. ❓ CMK status unknown. |
| 1.2 | **Identity model** | **System-assigned Managed Identity** on the Foundry account + each project; **disable local auth / API keys** on Foundry, Search, Doc Intelligence, Storage; Entra-only access. | ❌ Likely keys-on (default). Needs `disableLocalAuth: true`. |
| 1.3 | **Networking — private by default** | Foundry account, projects, AI Search, Key Vault, Storage, Doc Intelligence on **Private Endpoints** into a spoke VNet under your hub MG; **public network access = Disabled**; Private DNS zones linked to hub. | ❌ Usually not done. Hub-spoke MGs often exist (good baseline). |
| 1.4 | **Egress control** | Foundry **outbound = "Allow Azure services on the trusted list"** or use **Agent service VNet injection** + UDR through hub firewall for any internet calls (tools, MCP, web grounding). | ❌ Default egress. |
| 1.5 | **Secrets & keys** | All connection strings + SAS tokens in **Key Vault**; **purge protection on**, **RBAC mode** (not access policies), **CMK keys** for Foundry/Search/Storage. | ⚠️ Vault often exists; verify purge protection + RBAC mode. |
| 1.6 | **AI Gateway** | **APIM** in front of every model deployment for: tenant routing, throttling, **token-based rate limits**, semantic caching, model failover, audit. | ✅ APIM often exists — needs the **AI Gateway policies** wired up. |
| 1.7 | **Model catalog governance** | Lock model catalog via policy: only **approved models + versions + regions**; pin deployments to **PTU or Standard with quota caps**; block preview/community models unless waiver. | ❌ Typically not done. |
| 1.8 | **Project provisioning pattern** | Self-service "agent factory" via **Bicep/Terraform module + GitHub Actions/ADO pipeline** — devs request a project, pipeline creates project + Search index + connections under policy. | ❌ Usually manual. The "agent factory" requirement. |
| 1.9 | **Connections** | Use Foundry **connections** (not raw keys in code) to Fabric, Search, Storage, AOAI — backed by managed identity. | ⚠️ Partial — Search is in-account; data-tool connection latency is a frequent pain point. |
| 1.10 | **Tagging & cost allocation (FinOps)** | `Application`, `CostCenter`, `Environment`, `Owner`, `DataClassification`, `UseCase`, `ModelFamily` — inherited from RG; **Budget alerts per project**, **PTU vs PAYG decision matrix**. | ✅ Tag inheritance policy compliant; ❌ Per-project budgets/showback usually missing. |
| 1.11 | **DR / region strategy** | Pair the primary region with a secondary for model failover via APIM; Foundry account is regional — design for project-level replication of indexes/configs via IaC. | ❌ Single region. |

---

## 2. Guardrails & controls — policy, access, safety, model

Three layers: **Azure platform**, **Foundry runtime**, **content/model safety**.

### 2a. Azure-level guardrails (Azure Policy)

| Policy / Initiative | What it enforces | Why you need it |
|---|---|---|
| **AI Foundry LZA Policy Initiative** (custom set) | All AI resources private, no local auth, CMK on, diagnostic settings on, approved regions, approved SKUs | The single biggest LZ artifact — closes 80% of the "what should be on" question |
| `Cognitive Services should disable public network access` | Deny | Forces PE-only |
| `Cognitive Services should use customer-managed key` | Audit/Deny | Encryption sovereignty |
| `Cognitive Services accounts should disable local authentication` | Deny | Entra-only |
| `Configure Microsoft Defender for AI Services to be enabled` | DINE | **Closes the Defender-for-AI gap on dev** |
| `Allowed locations` for Cognitive Services | Deny | ✅ Often already at MG level — extend to AI types |
| `Deploy diagnostic settings to Log Analytics` (per AI resource type) | DINE | Powers section 3 below |
| Tag policies — `CostCenter`, `UseCase`, `Owner` required on AI RGs | Deny | Drives showback/budgets |

### 2b. Foundry RBAC & access

| Role | Assigned to | Scope |
|---|---|---|
| **Azure AI Account Owner** | Platform team (PIM-eligible) | Foundry account |
| **Azure AI Project Manager** | Project lead | Project |
| **Azure AI Developer** | Builders | Project |
| **Azure AI Inference Deployment Operator** | Pipeline SPN | Project |
| **Azure AI User** | App identity / agent runtime MI | Project |
| **Cognitive Services OpenAI User / Contributor** | App identities | Specific model deployment |
| **Search Index Data Reader / Contributor** | RAG identities | Index level |

Rules: **no Owner at subscription**, all standing access via **PIM**, app/runtime access via **Managed Identity only**, secrets exchange via **Key Vault references**.

### 2c. Content safety & model controls

| Control | Configuration |
|---|---|
| **Azure AI Content Safety** | Attached to every model deployment via APIM policy; categories: Hate, Sexual, Violence, Self-harm at threshold **Medium = block**; **Prompt Shields** on for jailbreak/indirect-injection detection |
| **Protected material detection** | On for code + text outputs (IP risk) |
| **Groundedness detection** | On for all RAG agents (Doc Intelligence + AI Search pipelines) |
| **Custom blocklists** | Per project — competitor names, PII patterns, internal codenames |
| **PII redaction** | At Doc Intelligence ingestion + at agent output |
| **System prompt hardening template** | Mandatory shared prefix injected by APIM (role bounds, refusal guidance, no-PII rule) |
| **Model allow-list** | GPT-4o, GPT-4o-mini, text-embedding-3-large, Phi-4 — pinned versions; preview models blocked |
| **Token / TPM caps** | Per project quota; APIM token-rate-limit policy as second wall |
| **Tool / MCP allow-list** | Each project can only attach approved tools; web grounding off by default |
| **Eval gate** | Continuous Evaluation in Foundry — quality + safety + groundedness scores must clear thresholds before a deployment is promoted dev→prod |

---

## 3. Monitoring & observability — telemetry, logs, usage, cost, health, latency

This is where tool-latency concerns get answered with data, not opinion.

### 3a. Telemetry plumbing (deploy once via policy)

| Source | Destination | What you get |
|---|---|---|
| Foundry account diagnostic settings → **Log Analytics workspace** (hub) | `AzureDiagnostics`, `AzureMetrics` | Account-level audit, throttling, model calls |
| Foundry project → Log Analytics | Project request logs, eval results | Per-use-case slicing |
| AI Search → Log Analytics | `OperationLogs`, `QueryLogs` | Index latency, throttled queries |
| APIM → Log Analytics + **Application Insights** | Gateway logs, token usage | End-to-end per-request trace, **prompt/response capture** (with PII scrubbing policy) |
| Document Intelligence → Log Analytics | API calls, latency | Ingestion pipeline health |
| Key Vault → Log Analytics | Secret access audit | Compliance |
| **Activity Log** (subscription) → Log Analytics + **Event Grid** | Deployment changes, role changes | Change forensics |
| Defender for Cloud — AI Workloads plan** | Microsoft Defender XDR | Prompt-injection alerts, data exfil, anomalous usage — **closes the Defender-for-AI gap** |

### 3b. App-side instrumentation (OpenTelemetry)

- **App Insights SDK + Azure Monitor OpenTelemetry distro** in every agent runtime.
- Auto-emit **GenAI semantic conventions**: `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.response.finish_reason`.
- Span structure: `user request → APIM → Foundry agent → tool call (data tool / Search / Doc Intelligence) → model → response`. This is what surfaces **where tool latency lives**.
- Enable **distributed tracing** end-to-end (W3C traceparent through APIM).

### 3c. Workbooks & dashboards (ship with the accelerator)

| Workbook | KPIs |
|---|---|
| **Foundry Operations** | Requests/min, TPM by deployment, throttled %, error rate, p50/p95/p99 latency by model + by project |
| **Agent Performance** | Per-agent: latency breakdown (model vs tool vs network), tool error rate, **data-tool query duration distribution** (directly answers latency concerns), groundedness score trend |
| **Content Safety** | Blocked prompts/responses by category, jailbreak detections, PII redaction count, top offending projects |
| **FinOps (the "finops" in the workspace name)** | $/day by project + model + tag, tokens by project, PTU utilization %, cost per successful request, forecast vs budget, top-N expensive prompts |
| **Compliance** | Policy compliance drift (Azure Policy → LA), Defender alerts, Key Vault rotation status, model version drift |
| **Health** | Resource Health rollup, dependency map (Foundry ↔ Search ↔ data tools ↔ Doc Intelligence), SLO burn-rate alerts |

### 3d. Alerts (deploy as Bicep)

| Alert | Threshold | Action |
|---|---|---|
| Model 429 throttling | > 5% over 5 min | Auto-scale PTU / failover via APIM |
| Agent p95 latency | > 8 s for 10 min | Page on-call |
| Tool span p95 latency (e.g. data tool) | > 3 s for 10 min | Notify data team — **a common top KPI** |
| Content Safety block rate | > 2× baseline | Notify security |
| Spend vs budget | 80% / 100% / 120% | Email project owner + finance |
| Defender for AI alert | Any High | ServiceNow / Teams |
| Key Vault secret expiring | < 30 days | Email vault owner |

### 3e. Cost / FinOps controls

- **Budgets per project** (Azure Budgets on RG or tag `UseCase`).
- **Cost views** in Cost Management filtered by `CostCenter=<your-cc>` (tag should already be there).
- **PTU vs PAYG decision** automated by usage workbook (recommend PTU when monthly tokens > break-even).
- **Cost anomaly detection** on Foundry meter.
- **Showback report** auto-emailed monthly to project owners.

---

## How this maps to a half-day workshop

| Block | Time | Deliverable |
|---|---|---|
| 1. Landing zone walkthrough | 60 min | Bicep + Terraform modules + policy initiative shipped in the repo |
| 2. Guardrails & RBAC | 45 min | Policy assignment, role map, content safety config |
| 3. Observability & FinOps demo | 45 min | Workbooks live on the dev AI RG, latency breakdown showing per-tool spans |
| 4. Defender + compliance | 30 min | Close the Defender-for-AI gap on dev live |
| 5. Roadmap to prod | 30 min | Promote pattern from dev → prod |
