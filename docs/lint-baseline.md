# Lint Baseline — klz-accelerator-finops

This document captures the agreed lint/security warning baseline for the
repo. CI gates fail if new warnings appear beyond the baseline counts below.
Warnings inside the baseline are accepted with a documented justification.

> All warnings represent **known carryover work** (tagged "P9 carryover" in
> the engine source). They are NOT regressions and NOT security issues.

---

## Terraform — tflint (azurerm plugin v0.29.0)

**Config:** [`infra/terraform/.tflint.hcl`](../infra/terraform/.tflint.hcl)

**CI invocation** (failure threshold = `error`, warnings reported but non-fatal):

```bash
cd infra/terraform
tflint --init
tflint --recursive --format compact --minimum-failure-severity error
```

| Severity | Count | Status |
|---|---|---|
| Error    | **0** | ✅ Must stay at 0 |
| Warning  | **11** | ⚠️ Tracked baseline — see table below |

### Baseline warning inventory

All 11 are `terraform_unused_declarations` on variables that are part of the
**stable public API surface** of the engine but whose downstream wiring is
deferred to a future iteration. They MUST be retained so that callers
(`*.tfvars` files, Bicep parity blueprints) continue to validate cleanly.

| # | File | Variable | Reason | Closes when |
|---|---|---|---|---|
| 1 | `variables.tf` | `hub_vnet_resource_id` | P9 hub-connected mode wiring not yet plumbed into `modules/spoke-network` | P9 |
| 2 | `variables.tf` | `hub_firewall_private_ip` | P9 hub-connected UDR target | P9 |
| 3 | `variables.tf` | `enable_forced_tunneling` | P9 hub-connected UDR toggle | P9 |
| 4 | `variables.tf` | `create_reverse_hub_peer` | P9 hub-side peering opt-in | P9 |
| 5 | `variables.tf` | `deploy_notifications` | `modules/observability/notifications` not wired in `main.tf` | P9 |
| 6 | `variables.tf` | `enable_notifications_logic_app` | Same — notifications wiring | P9 |
| 7 | `variables.tf` | `teams_webhook_url` | Same — notifications wiring | P9 |
| 8 | `variables.tf` | `notification_emails` | Same — notifications wiring | P9 |
| 9 | `variables.tf` | `otel_secondary_endpoint` | `modules/observability/otel-collector` not wired in `main.tf` | P9 |
| 10 | `modules/apim/main.tf` | `foundry_endpoint` | Reserved for inbound-policy XML templatefile() | P9 |
| 11 | `modules/apim/main.tf` | `foundry_account_id` | Same — APIM policy templating | P9 |

The `modules/hub-greenfield/main.tf` file uses a `# tflint-ignore-file` directive
because the entire module is a documented stub (5 vars, all unused).

> **CI baseline rule:** if `tflint --recursive` reports **>11 warnings or any
> error**, the PR job fails. Update this table simultaneously with the
> code change that resolves a baseline item.

### Plugin / ruleset versions (pinned)

- tflint: **0.63.1**
- tflint-ruleset-terraform (bundled): **0.15.0** (preset = recommended)
- tflint-ruleset-azurerm: **0.29.0**

---

## Terraform / Bicep / Dockerfile — trivy (config + secret scanners)

**Config:** [`.trivy.yaml`](../.trivy.yaml) + [`.trivy-secret.yaml`](../.trivy-secret.yaml)

**CI invocation:**

```bash
trivy config --severity HIGH,CRITICAL --config .trivy.yaml infra/
```

| Severity | Count | Status |
|---|---|---|
| CRITICAL | **0** | ✅ Must stay at 0 |
| HIGH | **0 (after exclusions)** | ✅ Must stay at 0 |
| MEDIUM | N/A — not gated | Informational |

### Documented exclusions

| Check ID | Reason | Re-enable when |
|---|---|---|
| AVD-AZU-0008 | Storage `allow_blob_public_access` false-positive on AVM dynamic blocks | AVM `avm-res-storage-storageaccount` ≥ 0.6 normalises the block |
| AVD-AZU-0027 | App Insights `workspace_id` false-positive on `avm-ptn-ai-foundry` ≤ 0.10 | AVM ptn-ai-foundry > 0.11 |

### Secret-scanner allow-list

| Pattern | Path scope | Reason |
|---|---|---|
| `<REPLACE-WITH-[A-Z0-9_-]+>` | `*.sample.bicepparam`, `*.sample.tfvars` | Sample-template placeholders |
| `DummyP@ssw0rd[0-9]+!QA` | any | QA-only dummy creds used in plan-validation logs |
| `ssh-ed25519 ...qa@klz-finops` | any | QA-only public key used in plan-validation logs |

---

## Bicep + Terraform — checkov

**Config:** [`.checkov.yaml`](../.checkov.yaml)

**CI invocation:**

```bash
checkov --config-file .checkov.yaml --directory infra
```

| Severity | Count | Status |
|---|---|---|
| FAILED (after skips) | **TBD on first CI run** | Baseline captured into `.checkov.baseline` |

### Skipped checks (with justification)

| Check ID | Title | Reason |
|---|---|---|
| CKV_AZURE_33 | Storage logging not LRS | Env-aware: dev=LRS, prod=ZRS by design |
| CKV_AZURE_109 | Key Vault firewall default allow | AVM dynamic-block FP — we set `network_acls.default_action = Deny` |
| CKV_AZURE_173 | APIM `min_api_version` not set | v1 property; v2 SKUs enforce TLS 1.2 implicitly |
| CKV_AZURE_190 | Storage account CMK encryption | Optional feature (`byor.cmk = true`) — not default |

---

## Bicep — PSRule (PSRule.Rules.Azure v1.47.0)

**Config:** [`ps-rule.yaml`](../ps-rule.yaml) + [`.ps-rule/options.yaml`](../.ps-rule/options.yaml)

**CI invocation** (uses standalone `bicep.exe` for file expansion):

```powershell
$env:PSRULE_AZURE_BICEP_PATH = "$env:USERPROFILE\.azure\bin\bicep.exe"  # or `which bicep`
Import-Module PSRule.Rules.Azure
Invoke-PSRule -InputPath infra/bicep/main.bicep -Module PSRule.Rules.Azure `
              -Option ps-rule.yaml -Outcome Fail
```

| Severity | Count | Status |
|---|---|---|
| Error    | **0**  | ✅ Must stay at 0 |
| Fail     | **11** | ⚠️ Tracked baseline — see table below |
| Pass     | **354+** | Informational |
| Skipped  | ~29k   | Rules not applicable to this template |

### Two findings already fixed in p8c

| Rule | Fix |
|---|---|
| `Azure.AppInsights.LocalAuth` | Added `DisableLocalAuth: true` to `app-insights.bicep` |
| `Azure.KeyVault.Firewall` | Changed KV `networkAcls.defaultAction` from `Allow` to `Deny` (with `AzureServices` bypass retained for ARM control plane) |

### Baseline finding inventory (11)

| # | Rule | Target | Reason for baseline | Future remediation |
|---|---|---|---|---|
| 1 | `Azure.Log.Replication` | LAW | Geo-replication adds 2× cost; dev/poc blueprints opt out | Enable in `prod-*` blueprints only |
| 2 | `Azure.Deployment.SecureParameter` | KV deployment | `name` parameter flagged as it ends in "Name" but is not a secret. Known FP on AVM key-vault | Pinned upstream; fix in AVM ≥ 0.14 |
| 3 | `Azure.AI.PublicAccess` | Foundry account | `publicNetworkAccess = Enabled` for dev — PE is the data path | Set `Disabled` in prod blueprints after enabling PE-only access |
| 4 | `Azure.AI.PrivateEndpoints` | Foundry account | PE IS created in `pe.bicep`, but the rule's resourceGraph lookup doesn't see cross-module PE. Known FP | Pinned; fix in PSRule.Rules.Azure ≥ 1.50 |
| 5 | `Azure.Search.QuerySLA` | AI Search | Basic SKU = 1 replica = no query SLA. Dev cost choice | Use `sku: 'standard'` + 2 replicas for prod SLA |
| 6 | `Azure.Search.IndexSLA` | AI Search | Basic SKU = 1 partition = no index SLA | Same — Standard SKU + 3 partitions for prod SLA |
| 7 | `Azure.APIM.EncryptValues` | APIM | Named values stored unencrypted; we use no secrets in named values today (all secrets in KV via APIM managed identity) | When we add KV-backed named values, set `secret: true` |
| 8 | `Azure.APIM.ProductApproval` | APIM | Products auto-approve subscriptions for accelerator demo flow | Set `subscriptionRequired: true, approvalRequired: true` for enterprise |
| 9 | `Azure.APIM.AvailabilityZone` | APIM | StandardV2 SKU AZ availability is region-dependent + 3× cost | Premium SKU only — enable in `prod-*` blueprints with AZ-capable regions |
| 10 | `Azure.APIM.MultiRegion` | APIM | Multi-region APIM is Premium SKU only | Same as #9 |
| 11 | `Azure.APIM.DefenderCloud` | APIM | Defender for APIs is tenant-level subscription opt-in | Document in deployment-guide.md as a post-deploy step |

> **CI baseline rule:** if PSRule reports **>11 fails or any error**, the
> PR job fails. New PRs must update this table simultaneously.

### Plugin / ruleset versions (pinned)

- PSRule: **2.9.0**
- PSRule.Rules.Azure: **1.47.0**
- Baseline: `Azure.GA_2024_12`
- Bicep CLI: **0.43.8** (standalone, not `az bicep`)

---

## Cross-stack parity diff — Pester (p8e, pending)

Pester-based harness that diffs `terraform show -json` against
`az deployment sub what-if -o json` for each blueprint. Documented here
once p8e lands.

---

## How to update this baseline

1. Make your code change.
2. Re-run the lint tool locally (commands above).
3. If the new warning count differs from the baseline, update the table
   AND add a row for the new/removed warning with justification.
4. Reviewer must verify the baseline-table delta matches the lint output.


---

## Cross-stack parity diff — `scripts/parity-diff.ps1`

**Config:** [`docs/parity-allowlist.json`](parity-allowlist.json)

**CI invocation:**
```powershell
pwsh -File scripts/parity-diff.ps1 -Blueprint smoke -SubscriptionId <sub-id>
```

**What it does:** Runs `terraform plan` → `terraform show -json` for the chosen tfvars and `az deployment sub what-if` for the matching bicepparam, then normalizes both to `{Type, Count}` lists and asserts the difference is contained in the per-blueprint allowlist. Fails CI with exit 1 if drift exceeds the allowlist.

### Documented systemic cross-stack asymmetries (all standalone blueprints)

| Resource type | TF - Bicep | Justification |
|---|---|---|
| `Microsoft.Insights/actionGroups` | +1 | TF stack always creates an action group; Bicep gates it behind `components.notifications.deploy` (off in smoke/POC) |
| `Microsoft.Insights/dataCollectionRules` | -2 | TF stack ports only 1 of 3 FinOps DCRs from Bicep — **P9 carryover** |
| `Microsoft.Insights/diagnosticSettings` | -5 | Bicep applies diagnostic settings to KV + 2 NSGs + VNet + Search (5 extra); TF only diagnostics the Foundry account — **P9 carryover** |
| `Microsoft.Insights/workbooks` | -1 | Bicep has 2 workbooks (cost + traffic); TF ships 1 (cost only) — **P9 carryover** |
| `Microsoft.Network/privateEndpoints` | -1 | TF skips KV PE in smoke posture (KV uses public access + Deny firewall); Bicep creates KV PE always — **shape preference, not a gap** |
| `Microsoft.Network/privateEndpoints/privateDnsZoneGroups` | -2 | TF inlines `private_dns_zone_group {}` as a sub-block of `azurerm_private_endpoint` (single resource); Bicep emits the group as a child resource (separate ID per PE). Same runtime behavior, different ARM shape. |

Baselines per blueprint live in [`docs/parity-allowlist.json`](parity-allowlist.json). New asymmetries must be added to the allowlist with a justification entry in this table.

---

## GitHub Actions workflows — `.github/workflows/`

**Validated with:** [actionlint v1.7.7](https://github.com/rhysd/actionlint) — all 3 workflows parse exit=0.

| Workflow | Trigger | Jobs |
|---|---|---|
| `pr.yml` | `pull_request` to main on `infra/` `shared/` `scripts/` `.github/` changes | (1) Terraform matrix (8 tfvars × fmt+init+validate+tflint+plan), (2) Bicep matrix (5 bicepparam × build + PSRule once on canonical + what-if), (3) Security (trivy + checkov), (4) Parity diff (TF↔Bicep on smoke, gated on terraform + bicep success) |
| `nightly-sandbox.yml` | cron `0 7 * * *` + `workflow_dispatch` | Deploy → smoke-verify → teardown loop. Stack and blueprint configurable. Uploads logs as artifacts. |
| `release.yml` | tag push `vX.Y.Z` | SemVer validation + git-log release notes generation + GH release publish |

**Required secrets** (set in repo settings → secrets → actions):
- `AZURE_CLIENT_ID` — Service principal (OIDC federated credential)
- `AZURE_TENANT_ID` — Entra tenant
- `AZURE_SUBSCRIPTION_ID` — Target subscription for what-if + nightly deploys

**OIDC federated credential** must be configured on the SP to trust `repo:<org>/<repo>:ref:refs/heads/main` and `repo:<org>/<repo>:pull_request`. See https://learn.microsoft.com/azure/active-directory/workload-identities/workload-identity-federation-create-trust.
