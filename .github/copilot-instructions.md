# Copilot instructions — `klz-accelerator-finops`

Production-grade, **dual-stack (Bicep + Terraform)** Azure landing zone for Microsoft Foundry / Azure OpenAI with FinOps showback, APIM AI Gateway governance, and content safety.

> [`AGENTS.md`](../AGENTS.md) at the repo root is the canonical workspace contract for any AI agent (Copilot CLI, Claude, Cursor, etc.). **Read it first.** This file echoes the rules most relevant to Copilot and adds gotchas learned the hard way.

## Read these first, in order

1. [`STATUS.txt`](../STATUS.txt) — phase tracker (`[DONE + DEPLOYED]`, `[SHIPPED — DEPLOY PENDING]`, `[NOT STARTED]`). **Grep this before starting new work.**
2. [`README.md`](../README.md) — what gets deployed, blueprints, toggles, quickstart, costs.
3. [`docs/architecture.md`](../docs/architecture.md) + [`docs/deployment-guide.md`](../docs/deployment-guide.md).

## Non-negotiable workspace rules

- **Dual-stack parity is enforced by CI.** Every change under `infra/bicep/` MUST have a mirrored change under `infra/terraform/` (same module names, same shape). `scripts/parity-diff.ps1` gates this. Allowlisted asymmetries live in [`docs/parity-allowlist.json`](../docs/parity-allowlist.json) — add an entry only with justification documented in [`docs/lint-baseline.md`](../docs/lint-baseline.md) §parity.
- **Never run `scripts/deploy.ps1 -Mode teardown` without explicit user confirmation.** A live workshop / customer deployment may be running.
- **PowerShell-first.** All operational helpers are `.ps1`. `e2e_test.py` is the sole Python exception.
- **Lint baseline is the contract.** Do not increase tflint / PSRule / trivy / checkov warning counts past [`docs/lint-baseline.md`](../docs/lint-baseline.md). If you must, update that file in the same PR with justification.

## Build / validate / single-test commands

```powershell
# Bicep build (lint + ARM compile) — run after any .bicep edit
az bicep build --file infra/bicep/main.bicep

# Terraform validate + lint — run after any .tf edit
cd infra/terraform
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate -no-color
tflint --recursive --format compact --minimum-failure-severity error   # baseline: 11 warnings, 0 errors

# Single blueprint plan (replace path) — the PR workflow runs a matrix
terraform plan -var-file=blueprints/smoke/smoke.tfvars -var="subscription_id=..." `
  -var="jumpvm_admin_password=..." -var="buildvm_ssh_public_key=..."
az deployment sub what-if --location eastus2 `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/blueprints/smoke/smoke.bicepparam

# PowerShell parse-check for a single script (matches the pr.yml ps-parse job)
pwsh -NoProfile -Command "`$err=`$null; [System.Management.Automation.Language.Parser]::ParseFile('scripts/smoke-policies.ps1',[ref]`$null,[ref]`$err); `$err"

# Cross-stack parity (single blueprint — requires az login + sub access)
./scripts/parity-diff.ps1 -Blueprint smoke -SubscriptionId <sub>

# Post-deploy verification (read-only, safe; live tenant required)
./scripts/smoke-verify.ps1   -Workload klzfin -Env dev -SubscriptionId <sub>
./scripts/smoke-policies.ps1 -Workload klzfin -Env prod -SubscriptionId <sub> -ExpectApim

# Deploy / teardown — DESTRUCTIVE, confirm with user
./scripts/deploy.ps1 -Mode { whatif | smoke | full | teardown } -Location eastus2
```

CI workflows under [`.github/workflows/`](workflows/):
- `pr.yml` — matrix Terraform×8 + Bicep×5 + trivy + checkov + parity + PS parse
- `nightly-sandbox.yml` — deploy → `smoke-verify` → `smoke-policies` (only on `prod-hub-connected`, with `-ExpectApim`) → teardown
- `release.yml` — semver tag → release notes

## High-level architecture (the big picture)

Subscription-scope deployment of 5 RGs prefixed `rg-{workload}-{tier}-{env}` (default `rg-klzfin-*-dev`):

| RG | Holds |
|---|---|
| `rg-klzfin-foundation-{env}` | LAW, App Insights, KV |
| `rg-klzfin-network-{env}` | Spoke VNet `10.50.0.0/20` (9-subnet catalog) + NSGs |
| `rg-klzfin-foundry-{env}` | Foundry account, projects, PEs, agent CAE |
| `rg-klzfin-platform-{env}` | APIM, AppGW, Bastion, JumpVM, BuildVM, CAE, Redis (semantic cache) |
| `rg-klzfin-finops-{env}` | Budgets, workbooks, action groups |

Both Bicep and Terraform compose the same modules under `infra/{bicep,terraform}/modules/{foundation,networking,ai-platform,ai-gateway,compute,observability,finops}/` — module names must match exactly. Five paired blueprints (`smoke`, `poc-standalone-spoke`, `poc-hub-connected`, `prod-standalone-with-fw`, `prod-hub-connected`) toggle per-persona defaults.

**APIM AI Gateway chokepoint** (`enforceApimChokepoint=true` on `prod-*`): Foundry + Search go `publicNetworkAccess=Disabled`, PE-subnet NSG denies everything except `APIMSubnet` (+ optional `AIFoundrySubnet` and `ContainerAppEnvironmentSubnet` bypasses). APIM is the single entry point with managed-identity auth to all backends. Default policy stack: token-limit, semantic-cache (Redis Enterprise), emit-token-metric (6 dims to App Insights), content-safety, prompt-shields, MI authentication.

## APIM AI Gateway gotchas

1. **Global `<backend />` silently drops the response body.** A self-closing `<backend />` (or empty `<backend></backend>`) at service scope makes APIM return `200 OK` with `Content-Length: 0` for every request — no error, no log. Always use `<backend><forward-request /></backend>` at global scope. See `apim-policies/inbound-emit-metrics.xml`.
2. **`<llm-content-safety>` needs `credentials.managedIdentity` on the backend.** Per [Microsoft docs](https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy) the `content-safety-backend` MUST include `credentials.managedIdentity.resource = "https://cognitiveservices.azure.com"`. Without it, APIM forwards unauthenticated → backend 401 → caller sees `403 ContentBlocked` for **every** prompt (benign included). Both stacks now configure it; Bicep needs `#disable-next-line BCP037`, TF needs `schema_validation_enabled = false`.
3. **StandardV2 master key isn't on the CLI.** `az apim subscription keys list --sid master` returns empty; use REST `POST .../subscriptions/master/listSecrets?api-version=2024-05-01` with explicit `Content-Length: 0`. `smoke-policies.ps1` does this.
4. **StandardV2 PNA quirks.** `publicIpAddresses` / `outboundPublicIPAddresses` return NULL — can't IP-allowlist a Foundry account with PNA=Enabled. Don't combine StandardV2 with PNA=Enabled + IP allowlist; use PE-only Foundry instead.
5. **APIM diagnostics names are case-sensitive.** Both required: `azuremonitor` (LAW transport for chargeback) AND `applicationinsights` (App Insights logger for emit-token-metric). `httpCorrelationProtocol` is VALID on `applicationinsights`, INVALID on `azuremonitor`.

## Foundry / Azure conventions

- **Naming**: workload=`klzfin`, env=`dev`, deterministic suffix from `uniqueString(...)` (Bicep) / `substr(sha256(...), 0, 4)` (TF). Parity asymmetry: names will differ literally; parity test compares `{Type, Count}` not names.
- **Foundry chat completions** require role `Cognitive Services OpenAI User` (`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`), **not** just `Cognitive Services User`. RBAC modules that grant only the latter fail at runtime.
- **App Insights** must have `CustomMetricsOptedInType: 'WithDimensions'` or `azure-openai-emit-token-metric` dimensions are silently dropped. AVM `insights/component:0.7.1` doesn't surface this — `app-insights.bicep` uses a direct resource with `#disable-next-line BCP037`.
- **Bicep `utcNow()`** is parameter-default-only (BCP065). Extract to a `param` with `utcNow()` default, then reference inline.
- **AVM models deprecated** as of 2025-11-14: `gpt-35-turbo`, `gpt-35-turbo-16k`. Use `gpt-4.1`, `o4-mini`, `text-embedding-ada-002`, `whisper`.

## Teardown gotcha — `legionservicelink` SAL

When Foundry agent injection (`enableFoundryAgentInjection=true`) is on, the CAE installs a `legionservicelink` Service Association Link on `AIFoundrySubnet` with `allowDelete=false`. After RG delete, the SAL orphans (subnetId=all-zeros) but blocks VNet delete (`InUseSubnetCannotBeDeleted`) for 30-60+ min until Microsoft.App RP reaps it. Azure CLI is **blocked** from DELETE on serviceAssociationLinks (`UnauthorizedClientApplication 04b07795-...`). `scripts/deploy.ps1 -Mode teardown` uses 3-phase ordering: (1) delete `capabilityHosts/default` + CAE via REST, (2) delete Foundry RG synchronously and purge soft-deleted account, (3) delete platform + hub RGs in parallel. Residual VNet+NSGs cost $0/day until the SAL reaps.

## PowerShell on Windows — `az.cmd` shim gotchas

- `az.cmd` mangles JMESPath `?` and `{}`. Quote queries; prefer post-filtering with `Where-Object`. Example: NOT `--query "[?starts_with(name,'klzfin')]"` — use `az ... -o json | ConvertFrom-Json | Where-Object { $_.name -like 'klzfin*' }`.
- `az rest` chokes on UTF-8 BOM with `'charmap' codec can't encode character '\ufeff'`. Use `curl.exe --output-file` (Windows) or `Invoke-WebRequest -SkipHttpErrorCheck` (cross-platform).
- For CI-portable scripts use `Invoke-WebRequest`, not `curl.exe` (fails on Linux runners) and avoid `NUL` (use temp files).

## Where to cite for new APIM/Foundry patterns

- APIM AI Gateway: [`Azure-Samples/AI-Gateway`](https://github.com/Azure-Samples/AI-Gateway) — the `labs/content-safety/main.bicep` and `labs/finops-framework/` are the closest reference implementations.
- Foundry enterprise readiness: [`docs/Foundry-Enterprise-Readiness.md`](../docs/Foundry-Enterprise-Readiness.md).
- Brownfield retrofit (existing APIM / existing Foundry): [`docs/Enterprise-Brownfield-Remediation-Plan.md`](../docs/Enterprise-Brownfield-Remediation-Plan.md) + [`docs/existing-apim-byo.md`](../docs/existing-apim-byo.md).

## Layout cheatsheet

| Path | Purpose | When to touch |
|---|---|---|
| `infra/bicep/main.bicep` | Subscription-scope orchestrator | Wire a new module here, mirror in `infra/terraform/main.tf` |
| `infra/{bicep,terraform}/modules/<name>/` | Resource modules — names must match across stacks | Add new module in BOTH stacks in the same PR |
| `infra/{bicep,terraform}/blueprints/<name>/` | 5 paired blueprints | Toggle defaults per persona; never put real customer IDs here |
| `infra/{bicep,terraform}/parameters/` | Ad-hoc parameter sets (`full`, `stage-b-toggles`, `enterprise-hub-connected.sample`) | Convenience entry points |
| `apim-policies/*.xml` | AI Gateway XML — loaded by both Bicep (`loadTextContent`) and TF (`file()`) | Single source of truth; both stacks inherit any fix |
| `apim-policies/fragments/*.xml` | Snippet fragments — contain `__PLACEHOLDER__` tokens replaced by the assembler at deploy time | Not standalone-valid XML — don't parse with `[xml]` |
| `policy/` | Azure Policy initiative (12 controls); audit-only by default | Promote to deny only in `prod-*` after baseline |
| `governance/agent-runtime/` | Fork of `microsoft/agent-governance-toolkit` @ `6f94b69` | Python, `pyproject.toml`, 126 pytest |
| `finops/chargeback/monthly-showback.kql` | Showback KQL | Joins `ApiManagementGatewayLlmLog ⨯ ApiManagementGatewayLogs ⨯ PRICING_CL ⨯ SUBSCRIPTION_QUOTA_CL` |
| `placeholders/` | Customer-fillable templates | **Never commit real customer values** |
| `scripts/` | Operational helpers (`.ps1`) | `deploy.ps1`, `smoke-verify.ps1`, `smoke-policies.ps1`, `parity-diff.ps1`, `grant-runtime-rbac.ps1` |

## Policy authoring quirks

- `mode: All` vs `Indexed`: sub-resources like `accounts/deployments` are **skipped** under `Indexed`. The Foundry model-allowlist policy uses `mode: All`.
- Initiative parameters in `policy/initiative/foundry-enterprise-baseline.json` default each control's effect to `Audit`. Promote to `Deny` only on prod blueprints after a baseline pass via `policy/assign-mg-initiative.ps1` parameter overrides.
