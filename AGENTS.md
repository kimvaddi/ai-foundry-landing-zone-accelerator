# AGENTS.md — `klz-accelerator-finops`

Production-grade, **dual-stack (Bicep + Terraform)** Azure landing zone for Microsoft Foundry / Azure OpenAI with FinOps showback, APIM AI Gateway governance, and content safety. Pre-workshop tracker for a customer engagement.

**Read these first**, in order:

1. [`STATUS.txt`](STATUS.txt) — **canonical phase tracker** (~770 lines). Phase tags: `[DONE + DEPLOYED]`, `[SHIPPED — DEPLOY PENDING]`, `[NOT STARTED]`. Trust the tags but spot-check the files — STATUS has drifted before. **Do not start any new work without grep'ing this file first.**
2. [`README.md`](README.md) — what gets deployed, blueprints, toggles, quickstart, cost guidance.
3. [`docs/architecture.md`](docs/architecture.md) and [`docs/deployment-guide.md`](docs/deployment-guide.md) — design + step-by-step.

## Critical workspace rules

- **Dual-stack parity is enforced by CI.** Every change under `infra/bicep/` MUST have a mirrored change under `infra/terraform/` (same module names, same shape). The PR check runs `scripts/parity-diff.ps1` against the `smoke` blueprint. Allowlisted differences live in [`docs/parity-allowlist.json`](docs/parity-allowlist.json) — add an entry there only with justification.
- **A live deployment may be running in a sandbox / workshop subscription.** Real subscription IDs and customer names are kept out of this file — check with the operator before any destructive action. **Never run `scripts/deploy.ps1 -Mode teardown` without explicit user confirmation.**
- **PowerShell-first.** All scripts are `.ps1`. The Azure CLI through `az.cmd` mangles JMESPath `?` and `{}` — quote queries and prefer post-filtering with `Where-Object`. See [user memory: `azure-cli-on-powershell.md`].
- **Lint baseline is the contract.** Do not add new tflint, PSRule, trivy, or checkov warnings beyond the counts in [`docs/lint-baseline.md`](docs/lint-baseline.md). If you must, update that file in the same PR with a justification.

## Build / validate / verify (what agents will run automatically)

```powershell
# Bicep build (lint + ARM compile) — run after any .bicep edit
az bicep build --file infra/bicep/main.bicep

# Terraform validate + lint — run after any .tf edit
cd infra/terraform
terraform fmt -recursive
terraform init -backend=false -input=false
terraform validate -no-color
tflint --recursive --format compact --minimum-failure-severity error

# Cross-stack parity (requires az login + sub access)
./scripts/parity-diff.ps1 -Blueprint smoke

# Post-deploy health check (read-only, safe)
./scripts/smoke-verify.ps1 -Workload klzfin -Env dev -SubscriptionId <sub>

# Deploy / teardown — DESTRUCTIVE, confirm with user
./scripts/deploy.ps1 -Mode { whatif | smoke | full | teardown } -Location eastus2
```

CI workflows: [`.github/workflows/pr.yml`](.github/workflows/pr.yml) (matrix TF×8 + Bicep×5 + parity), [`nightly-sandbox.yml`](.github/workflows/nightly-sandbox.yml) (deploy→verify→teardown loop), [`release.yml`](.github/workflows/release.yml).

## Layout cheatsheet

| Path | Purpose | When to touch |
|---|---|---|
| `infra/bicep/main.bicep` | Subscription-scope orchestrator | Wire new module here, mirror in `infra/terraform/main.tf` |
| `infra/bicep/modules/{foundation,networking,ai-platform,ai-gateway,compute,observability,finops}/` | Resource modules | Match Terraform names exactly |
| `infra/{bicep,terraform}/blueprints/<name>/` | 5 paired blueprints (`smoke`, `poc-*`, `prod-*`) | Toggle defaults per persona |
| `apim-policies/*.xml` | AI Gateway XML, importable into BYO APIM | See gotchas below |
| `policy/` | Custom Azure Policy initiative (12 controls); `mg/main.bicep` creates the AI Landing Zone MG | Audit-only by default |
| `governance/agent-runtime/` | Fork of `microsoft/agent-governance-toolkit` @ `6f94b69` | Python, `pyproject.toml` + 126 pytest |
| `finops/chargeback/monthly-showback.kql` | Showback KQL | Joins `ApiManagementGatewayLlmLog ⨯ ApiManagementGatewayLogs ⨯ PRICING_CL ⨯ SUBSCRIPTION_QUOTA_CL` |
| `scripts/` | All `.ps1` operational helpers | `Validate-Workbook.ps1`, `e2e_test.py` (Python) are exceptions |
| `placeholders/` | Customer-fillable templates (`subscriptions.template.txt`, `azure-targets.template.md`, `stakeholders.template.md`) | Never commit real customer values here |
| `docs/` | All deep-dive docs — link, don't duplicate | See [`docs/lint-baseline.md`](docs/lint-baseline.md), [`docs/Enterprise-Brownfield-Remediation-Plan.md`](docs/Enterprise-Brownfield-Remediation-Plan.md) |

## Conventions

- **Naming**: workload=`klzfin`, env=`dev`, deterministic suffix `c6ej` (from `uniqueString(...)`). 5 RGs all prefixed `rg-klzfin-*-dev`.
- **Networking**: spoke VNet `10.50.0.0/20`, 9-subnet catalog. APIM StandardV2 deployed cannot be VNet-injected (calls Foundry via MI through public endpoint).
- **Foundry chat completions** require role `Cognitive Services OpenAI User` (`5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`), not just `Cognitive Services User`. RBAC modules that grant only the latter fail at runtime.
- **APIM diagnostics**: two are required and case-sensitive — `azuremonitor` (LAW transport, chargeback) and `applicationinsights` (App Insights logger, emit-token-metric). `httpCorrelationProtocol` is VALID on `applicationinsights`, INVALID on `azuremonitor`.
- **App Insights** must have `CustomMetricsOptedInType: 'WithDimensions'` or `azure-openai-emit-token-metric` dimensions are silently dropped at ingestion (AVM `insights/component:0.7.1` doesn't surface this — `app-insights.bicep` uses a direct resource with `#disable-next-line BCP037`).
- **Bicep `utcNow()`** is parameter-default-only (BCP065). Extract to a `param` with `utcNow()` default, then reference inline.
- **AVM models deprecated** as of 2025-11-14: `gpt-35-turbo`, `gpt-35-turbo-16k`. Use `gpt-4.1`, `o4-mini`, `text-embedding-ada-002`, `whisper`.

## When in doubt

- For APIM AI Gateway patterns: cite [Azure-Samples/AI-Gateway labs](https://github.com/Azure-Samples/AI-Gateway), don't invent. The `labs/finops-framework/` is near-identical to our target state.
- For Foundry enterprise readiness: cross-check [`docs/Foundry-Enterprise-Readiness.md`](docs/Foundry-Enterprise-Readiness.md).
- For brownfield / existing APIM: [`docs/Enterprise-Brownfield-Remediation-Plan.md`](docs/Enterprise-Brownfield-Remediation-Plan.md) + [`docs/existing-apim-byo.md`](docs/existing-apim-byo.md).
- For policy authoring: cross-check `mode: All` vs `Indexed` (sub-resources like `accounts/deployments` are skipped under `Indexed`); see [user memory: `azure-policy.md`].
