# KLZ FinOps Accelerator — Agent Runtime Governance

Forked policy baseline for runtime AI-agent governance, derived from the
Microsoft [`agent-governance-toolkit`](https://github.com/microsoft/agent-governance-toolkit).

> **Status**: Phase B.1, **Wave 2 shipped**. Seven policy templates + a loader + a 126-test pytest suite that proves the fork applies the KLZ deltas and both composed baselines (dev and prod) enforce what the analysis doc promised.

---

## Why this exists

A common ask from enterprise teams is **agent-runtime governance** on top of the FinOps
accelerator's resource-layer controls. The upstream agent-governance-toolkit ships strong defaults for
five enterprise concerns (`api-gateway`, `cost-controls`, `enterprise`,
`research-agent`, `mcp-server`, …). The work in this directory:

**Wave 1 (dev ring)** — `klz-baseline.yaml`:
1. Forks the three most relevant templates (`api-gateway`, `cost-controls`,
   `enterprise`) and re-shapes them to KLZ-specific reality (APIM FQDN,
   Azure-OpenAI-only providers, the chargeback dimension set wired up in
   Phase A.5, etc.).
2. Adds a KLZ-only composition template, `klz-baseline.yaml`, that pulls the
   three forked templates together via `include:` and layers on two
   KLZ-specific policies:
   - `klz_required_chargeback_headers` — fail-closed on any agent call
     missing `x-project-name` / `x-use-case` / `x-cost-center`.
   - `klz_apim_only_egress` — SIGKILL on any agent egress that isn't to an
     allowed Azure FQDN.

**Wave 2 (prod ring)** — `klz-production.yaml`:
1. Forks two more upstream templates (`production`, `data-protection`) and
   re-shapes them for KLZ:
   - `production.yaml` — allowlist-only egress to KLZ Azure FQDNs only,
     tighter LLM rate limits (20/min, down from 30), `max_tokens` raised
     to 8000 for gpt-4o, audit export to Log Analytics + App Insights +
     OTel, env-var-gated notification channels.
   - `data-protection.yaml` — adds `klz_azure_secret_protection` policy
     (Azure subscription UUID / AccountKey / SAS token regex, SIGKILL),
     SOC2 added to compliance frameworks, Azure secrets added to data
     classification taxonomy.
2. Adds the prod composition template `klz-production.yaml` that pulls
   `enterprise + api-gateway + production + data-protection` and layers on
   four KLZ-specific policies:
   - `klz_required_chargeback_headers` (re-asserted from Wave 1)
   - `klz_apim_only_egress` (re-asserted from Wave 1)
   - `klz_prod_spend_cap` — $100/day, $2500/month
   - `klz_prod_model_allowlist` — only the four models actually deployed

3. Both compositions share a `loader.py` with two halves: a raw template
   loader and a `compose_policy()` that resolves `include:` chains.

---

## Upstream attribution

| | |
|---|---|
| **Repository** | `microsoft/agent-governance-toolkit` |
| **Path** | `agent-governance-python/agent-os/templates/policies/` |
| **Pinned commit** | `6f94b69f4c524f5c87227db0609e3d28deba7fb7` |
| **Upstream license** | MIT (Microsoft Corporation) |
| **KLZ deltas** | Enumerated in the header block at the top of each YAML file under `policies/`; the MIT license header on `loader.py` lists the pinned upstream commit. |

The MIT license header is preserved at the top of `loader.py` and every YAML
header block enumerates KLZ deltas vs upstream so anyone can diff against
the pinned commit.

---

## Repo layout

```
governance/agent-runtime/
├── README.md                       (this file)
├── loader.py                       MIT-attributed; list/load + compose_policy()
├── policies/
│   ├── api-gateway.yaml            Forked (Wave 1) — URL allowlist/blocklist for KLZ
│   ├── cost-controls.yaml          Forked (Wave 1) — Azure-OpenAI-only, $25/day dev cap
│   ├── enterprise.yaml             Forked (Wave 1) — Entra/Key Vault/LAW integrations
│   ├── klz-baseline.yaml           NEW (Wave 1) — dev composition + chargeback enforcement
│   ├── production.yaml             Forked (Wave 2) — allowlist-only, write-block, SoD approvals
│   ├── data-protection.yaml        Forked (Wave 2) — PII / financial / PHI / Azure-secret detection
│   └── klz-production.yaml         NEW (Wave 2) — prod composition + $100/day cap + model allowlist
├── tests/
│   ├── conftest.py                       sys.path bootstrap
│   ├── _engine.py                        TEST FIXTURE only — synthetic evaluator
│   ├── test_loader.py                    Discovery + raw YAML loading (Wave 1+2)
│   ├── test_customizations.py            Every Wave 1 KLZ delta is in place
│   ├── test_customizations_wave2.py      Every Wave 2 KLZ delta is in place
│   ├── test_composition.py               Wave 1 include: chains + merge semantics
│   ├── test_policy_semantics.py          Wave 1 (klz-baseline) end-to-end
│   └── test_policy_semantics_wave2.py    Wave 2 (klz-production) end-to-end
├── pyproject.toml                  pytest config
├── requirements.txt                pyyaml + pytest
└── .venv/                          (gitignored)
```

---

## How to use it

### Load a single template

```python
from governance.agent_runtime.loader import load_policy_yaml

cost = load_policy_yaml("cost-controls")
print(cost["budget_reset"]["monthly_budget_usd"])  # 750.0
```

### Compose the KLZ baseline

```python
from governance.agent_runtime.loader import compose_policy

policy = compose_policy("klz-baseline")
# Resolved dict:
#   * `include:` stripped
#   * `policies[]` unioned (right-wins by name)
#   * `network.allowlist` / `network.blocklist` / `signals.enabled` unioned
#   * everything else deep-merged, right wins
```

### List available templates

```python
from governance.agent_runtime.loader import list_templates

list_templates()
# ['api-gateway', 'cost-controls', 'data-protection', 'enterprise',
#  'klz-baseline', 'klz-production', 'production']
```

### Compose the KLZ PROD ring

```python
from governance.agent_runtime.loader import compose_policy

prod = compose_policy("klz-production")
# Resolved dict from: enterprise + api-gateway + production + data-protection
# plus four KLZ-only policies on top.
#
# Note: cost-controls is intentionally NOT included — its $25/day dev cap is
# too tight for prod. Use the klz_prod_spend_cap policy ($100/day) instead.
```

---

## What KLZ changed vs upstream

### `cost-controls.yaml`
- `rate_limits.providers` — replaced `openai/anthropic/google` with a single
  `azure_openai` (rpm 60, daily_spend_limit_usd 25). KLZ agents only talk to
  Foundry via APIM.
- `policies[daily_spend_limit].daily_limit_usd` — `100` → `25` (dev cap).
- `policies[model_tier_control].allowed_models` — replaced with the four
  models actually deployed in KLZ: `gpt-4o-mini`, `gpt-4o`,
  `text-embedding-3-large`, `o3-mini`.
- `policies[model_tier_control].blocked_models` — added explicit list of the
  public-provider models (gpt-4-turbo, claude-*, gemini-*) so a typo in
  agent code fails loud.
- `cost_tracking.dimensions` — extended with `project_name`, `use_case`,
  `cost_center`, `subscription_id` so the OTel export matches the chargeback
  KQL shipped in Phase A.5.
- `cost_tracking.metrics.opentelemetry` — points at
  `${OTEL_EXPORTER_OTLP_ENDPOINT}` (gRPC).
- `budget_reset.monthly_budget_usd` — `5000` → `750` (dev cap).

### `api-gateway.yaml`
- `network.allowlist` — replaced upstream allowlist with KLZ Azure FQDNs:
  - `apim-klzfin-dev-c6ej.azure-api.net`
  - `*.cognitiveservices.azure.com`
  - `*.openai.azure.com`
  - `*.blob.core.windows.net`
- `network.blocklist` — added explicit public-AI endpoints
  (`api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com`,
  `api.groq.com`, `api.perplexity.ai`) on top of upstream's anonymisers/.onion
  blocks.
- `network.default_action` — `allow` → `deny` (whitelist-only).
- `policies[url_validation].exceptions` — emptied (no localhost exception).
- `tls.min_version` — `1.2` → `1.3`.
- `policies[per_domain_rate_limit].domains[*.azure-api.net].rpm` — 120 rpm
  for the KLZ APIM.

### `enterprise.yaml`
- `policies[network_restrictions].allow.domains` — only KLZ-allowed Azure
  FQDNs.
- `policies[cost_controls].limits.max_cost_per_day_usd` — 25 (matches
  cost-controls).
- `integrations.observability.opentelemetry.endpoint` —
  `${OTEL_EXPORTER_OTLP_ENDPOINT}`.
- `integrations.observability.application_insights.connection_string` —
  `${APPLICATIONINSIGHTS_CONNECTION_STRING}` (matches Phase A.5b wiring).
- `audit.export.destinations` — `log_analytics` (custom table
  `KlzAgentAudit_CL` via DCR) + `opentelemetry`.
- `integrations.sso.provider` — `entra`.
- `integrations.secrets_manager.provider` — `key_vault`.
- `integrations.sso.required_groups` — `klz-agent-users`,
  `klz-agent-developers`.
- `notifications.channels` — `${COMPLIANCE_EMAIL}` / `${CISO_EMAIL}`.
- `audit.fields` — added `correlation_id` so traces stitch with App Insights.

### `klz-baseline.yaml` (NEW)
Composition file with:
```yaml
include: [enterprise, api-gateway, cost-controls]
policies:
  - name: klz_required_chargeback_headers
    require_headers: [x-project-name, x-use-case, x-cost-center]
    action: SIGSTOP
  - name: klz_apim_only_egress
    allow_domains: [*.azure-api.net, *.cognitiveservices.azure.com, ...]
    deny: ["*"]
    action: SIGKILL
settings:
  human_approval_required: true
  fail_closed: true
  auto_continue_on_warn: false
```

### `production.yaml` (Wave 2)
- `policies[tool_allowlist].allow[http_request].domains` — replaced upstream
  `*.company.com, api.openai.com, api.anthropic.com` with KLZ-Azure-only
  FQDNs (APIM, cognitiveservices, openai.azure.com, blob.core.windows.net).
- `policies[tool_allowlist].allow[http_request].methods` — added `POST`
  (upstream only allowed `GET`; AI agents need POST for chat completions).
- `policies[strict_rate_limits].limits[llm_call]` — `max_per_minute` 30→20,
  `max_per_hour` 500→300 (matches APIM token-limit policy calibration).
- `policies[resource_limits].limits[max_tokens_per_call]` — 4000→8000 for
  gpt-4o's 128k context window.
- `policies[network_allowlist].allow[http_request].domains` — same KLZ
  Azure-only set, `deny: ["*"]`, SIGKILL.
- `audit.log_path` — env-var driven (`${KLZ_AUDIT_LOG_PATH}`).
- `audit.export.destinations` — replaced syslog/webhook with `log_analytics`
  (`KlzAgentAudit_CL`), `application_insights`, `opentelemetry`. Optional
  SIEM webhook gated by `${SIEM_WEBHOOK_URL}`.
- `notifications.channels` — pagerduty / security_team / compliance_team
  all env-var-gated (won't fire in dev without the env vars set).
- Kept upstream: SIGSTOP/SIGKILL/SIGCONT/SIGUSR1/SIGUSR2 signals; the full
  `block_write_operations` config (file_write, INSERT/UPDATE/DELETE/DROP/
  TRUNCATE/ALTER, shell_exec, PUT/DELETE/PATCH); `sensitive_tool_approval`
  six-tier SoD model (dba_team 30min, release_manager 60min, sre_team 15min,
  privacy_officer 30min, finance_team 15min, platform_team 30min);
  `destructive_operations` / `credential_protection` / `pii_protection`.

### `data-protection.yaml` (Wave 2)
- **NEW policy `klz_azure_secret_protection`** (critical, SIGKILL, scope
  `[output]`): regex deny on Azure subscription UUIDs, AccountKey/StorageKey
  base64 patterns, SAS tokens (`sig=...`, `sv=YYYY-MM-DD&...`), connection
  strings (`DefaultEndpointsProtocol=`, `Endpoint=sb://...`).
- `policies[data_retention_warnings].severity` — `medium` → `low`
  (false-positive heavy on legitimate Redis usage).
- `audit.log_path` — env-var driven
  (`${KLZ_DATA_PROTECTION_AUDIT_LOG_PATH}`); enterprise.yaml owns the
  centralized LAW + App Insights + OTel export.
- `compliance.frameworks` — added `SOC2`.
- `compliance.data_classification.confidential` — added
  `azure_subscription_id`.
- `compliance.data_classification.restricted` — added `azure_storage_key`,
  `sas_token`.
- Kept upstream: `pii_detection` (SSN/CC/email/phone/passport/license),
  `financial_data_protection`, `health_data_protection` (HIPAA),
  `safe_logging`, `data_export_controls`, `encryption_requirements`,
  `third_party_sharing`.

### `klz-production.yaml` (Wave 2 — NEW)
Composition file with:
```yaml
include: [enterprise, api-gateway, production, data-protection]
# NOTE: cost-controls is intentionally NOT included (dev cap too tight).
network:
  allowlist: ["apim-klzfin-*.azure-api.net"]  # unioned with api-gateway.yaml
  default_action: deny
policies:
  - name: klz_required_chargeback_headers     # re-asserted from Wave 1
  - name: klz_apim_only_egress                # re-asserted from Wave 1
  - name: klz_prod_spend_cap                  # $100/day, $2500/month
  - name: klz_prod_model_allowlist            # only KLZ-deployed models
settings:
  human_approval_required: true
  fail_closed: true
  auto_continue_on_warn: false
  debug_mode: false
```

---

## Required environment variables

Agents loading these policies need:

| Variable | Used in | Phase that wires it |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | cost-controls / enterprise / production | B.2 (OTel collector) |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | enterprise / production | **A.5b — already live** |
| `LOG_ANALYTICS_WORKSPACE_ID` | enterprise / production audit.export | A.5 — already live |
| `LOG_ANALYTICS_SHARED_KEY` | enterprise / production audit.export | B.3 (DCR + custom table) |
| `KLZ_AUDIT_LOG_PATH` | production.yaml (audit.log_path) | optional, defaults to `./logs/production-audit.log` |
| `KLZ_DATA_PROTECTION_AUDIT_LOG_PATH` | data-protection.yaml (audit.log_path) | optional, defaults to `./logs/data-protection-audit.log` |
| `SIEM_WEBHOOK_URL` | production.yaml (optional SIEM destination) | B.4 (optional) |
| `AUDIT_WEBHOOK_TOKEN` | production.yaml (optional SIEM auth) | B.4 (optional) |
| `PAGERDUTY_KEY` | production.yaml (notifications) | B.4 |
| `SECURITY_WEBHOOK_URL` | production.yaml (notifications) | B.4 |
| `COMPLIANCE_EMAIL` | enterprise / production notifications | B.4 |
| `CISO_EMAIL` | enterprise.notifications | B.4 |

App Insights and LAW are already live (Phase A.5 / A.5b). Everything else
ships in Phase B. All env-var-gated channels in `production.yaml` use
`enabled_when:` so they are silent in dev when the variable is unset.

---

## How to run the tests

From `governance/agent-runtime/`:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
pytest -v
```

Expected:

```
============================ 126 passed in 2.18s ==============================
```

The suite covers seven concerns:

| File | What it asserts |
|---|---|
| `test_loader.py` | Discovery, raw load, error-handling, kernel mode — all 7 templates. |
| `test_customizations.py` | Every Wave 1 KLZ delta (api-gateway, cost-controls, enterprise, klz-baseline) is present. |
| `test_customizations_wave2.py` | Every Wave 2 KLZ delta (production, data-protection, klz-production) is present. |
| `test_composition.py` | Wave 1 `include:` chains resolve, lists union correctly, no dup policy names, cycle detection. |
| `test_policy_semantics.py` | Composed klz-baseline (dev) denies shadow-AI, SSRF, credential-in-URL, missing chargeback headers, non-KLZ models, over-budget calls. |
| `test_policy_semantics_wave2.py` | Composed klz-production (prod) denies non-Azure egress, missing chargeback headers, over-$100/day calls, non-allowlisted models. |

---

## Adding a new agent

The pattern is "compose, don't fork":

1. Drop a new YAML in `policies/`, e.g. `my-agent.yaml`:
   ```yaml
   kernel:
     template: my-agent
     mode: strict
   include: [klz-baseline]                # inherit everything
   policies:
     - name: my_agent_specific_thing
       severity: high
       …
   ```
2. Add a customization test in `tests/test_customizations.py`.
3. Add a semantics test in `tests/test_policy_semantics.py`.
4. `pytest -v`.

The loader's `compose_policy()` handles arbitrary include depth and cycles.

---

## Known gaps (intentional, B.2+)

| Gap | Plan |
|---|---|
| `loader.py` doesn't ship a runtime engine. | The synthetic `_engine.py` is a **test fixture only**. Production enforcement runs in the upstream `agent-os` runtime (or whatever runtime the consuming team chooses). The fork ships the *policy*, not the *enforcer*. |
| OTel collector isn't deployed yet. | Phase B.2 — Dapr sidecar or OTel collector daemonset, depending on AKS-vs-Container-Apps decision. |
| Custom LAW table `KlzAgentAudit_CL` isn't created yet. | Phase B.3 — DCR + DCE + custom table via Bicep AVM. |
| Notification channels are env-var placeholders. | Phase B.4 — Logic Apps / Action Groups, parameterized via Bicep. |
| No regulated-industry overlays (HIPAA / PCI-DSS / FedRAMP). | **Wave 3** — `klz-regulated-*.yaml` overlays on top of `klz-production`. |

---

## Maintenance: re-syncing with upstream

When upstream `agent-governance-toolkit` ships a new release:

```powershell
cd c:\Count\AGT\agent-governance-toolkit
git fetch origin
git log --oneline 6f94b69..origin/main -- agent-governance-python/agent-os/templates/policies/
```

Review the diff. For each upstream change:

- If the change is in a section the KLZ delta block (top of each YAML)
  doesn't list, copy it across.
- If it touches a KLZ delta line, decide whether to accept upstream
  (update the delta block) or hold (document in the delta block).

Then bump the commit pin in this README and in `loader.py`'s header, and
run `pytest -v`. Green = good.
