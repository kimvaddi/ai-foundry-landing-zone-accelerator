# Deploy Guide — Brand-new to Azure

**Audience:** anyone first-time deploying this repo
**Time required:** ~25 minutes (smoke deploy + validation + teardown)
**Cost:** under $1 if you tear down within ~1 hour
**You will not break anything** — everything goes into two new resource groups, and the teardown command deletes them cleanly.

---

## Part 1 — One-time setup on your laptop (~10 min)

You need three things installed: **Git**, **Azure CLI**, and **PowerShell 7**. Skip any you already have.

### 1.1 Windows

Open **Windows PowerShell** (Start menu → type "PowerShell" → Enter) and paste:

```powershell
winget install --id Git.Git -e --source winget
winget install --id Microsoft.AzureCLI -e --source winget
winget install --id Microsoft.PowerShell -e --source winget
```

Close PowerShell and re-open it as **PowerShell 7** (Start menu → "PowerShell 7"). All commands below run in PowerShell 7, not the old Windows PowerShell.

### 1.2 macOS

```bash
brew install git
brew install azure-cli
brew install --cask powershell
```

Then open **pwsh** from Terminal.

### 1.3 Verify

```powershell
git --version          # any version >= 2.40
az --version           # any version >= 2.60
$PSVersionTable.PSVersion   # should print 7.x
```

If any command says "not recognized", close and re-open your terminal.

---

## Part 2 — Get the code (~2 min)

### Option A — I sent you a GitHub link

```powershell
cd ~\Documents
git clone <repo-url-Kim-sent-you> klz-accelerator-finops
cd klz-accelerator-finops
```

### Option B — I sent you a zip file

1. Right-click the zip → **Extract All** → pick `Documents`
2. Open PowerShell 7:
   ```powershell
   cd ~\Documents\klz-accelerator-finops
   ```

You should now see folders like `infra/`, `scripts/`, `docs/`. Confirm with:

```powershell
Get-ChildItem
```

---

## Part 3 — Sign in to Azure (~3 min)

You need an Azure subscription with **Contributor** rights. If you don't have one, ask your admin for a sandbox subscription.

```powershell
# Sign in (opens a browser tab — pick your work account)
az login

# See which subscriptions your account can use
az account list --query '[].{name:name, id:id}' -o table

# Pick the one you want to deploy into (copy its id from above)
az account set --subscription "<paste-subscription-id-here>"

# Confirm you're pointed at the right place
az account show --query '{sub:name, tenant:tenantId}' -o table
```

> **Important:** the account you sign in with must have the **Contributor** role on this subscription. If you get permission errors during deploy, that's why — ask your Azure admin to grant it.

---

## Part 4 — Deploy (~5 min)

This deploys the **smoke** profile (`-Mode smoke` → `infra/bicep/parameters/dev.bicepparam`): a standalone landing zone with the full Stage A networking footprint (spoke VNet, all 21 private DNS zones, Foundry + Key Vault private endpoints) but with the cost-heavy bits off (APIM, App Gateway, Bastion). Lands ~60 Azure resources in two brand-new resource groups.

```powershell
./scripts/deploy.ps1 -Mode smoke -Workload klzfin -Environment dev -Location eastus2
```

What happens:
1. Script checks that `az` and `bicep` CLIs are installed
2. Registers all required resource providers (idempotent — skips any already Registered)
3. Prints which subscription and tenant you're about to deploy into — **stop and verify** this looks right
4. Submits the deployment and waits for it to finish (~5 min on a clean sub, longer if it retries anything)
5. Saves a JSON file with the resource IDs and validation outputs

**If you see:**
- ✅ `Deployment succeeded` — go to Part 5
- ❌ `InsufficientResourcesAvailable` on AI Search → `westus2` is already wired in `infra/bicep/parameters/dev.bicepparam`. If it still fails, edit `param searchLocation = 'westus2'` in that file to `'eastus'` and re-run.
- ❌ `ResourceNotFound` on Log Analytics workspace partway through → ARM eventual-consistency race. Re-run the same deploy command; it's idempotent.
- ❌ `Could not generate subnet for network ... and CIDR value '4'` → you're on a pre-Stage-A revision. Pull latest; the `cidrSubnet` calls were fixed in June 2026.
- ❌ Anything else → copy the full error and send it to the maintainer.

---

## Part 5 — Verify it worked (~2 min)

```powershell
./scripts/validate.ps1 -Workload klzfin -Environment dev
```

You should see all green `PASS` lines for:
- Both resource groups exist (`rg-klzfin-platform-dev`, `rg-klzfin-foundry-dev`)
- Log Analytics workspace, Key Vault, Foundry account, AI Search
- Spoke VNet `vnet-klzfin-dev-<suffix>` on `10.50.0.0/20`
- 21 private DNS zones with VNet links to the spoke
- Foundry private endpoint resolving to **two** A records (`cognitiveservices.azure.com` + `openai.azure.com`)
- Key Vault private endpoint resolving to `vaultcore.azure.net`
- Custom log tables `PRICING_CL` and `SUBSCRIPTION_QUOTA_CL`
- Data Collection Endpoint + 2 Data Collection Rules
- Workbooks
- Foundry endpoint URL is reachable
- `disableLocalAuth=true` (enterprise security baseline)
- Validation guard outputs `_validation_hubVnet=OK` and `_validation_forcedTunnel=OK`

### See it in the Azure portal

1. Open <https://portal.azure.com>
2. Top search bar → type `rg-klzfin-foundry-dev` → click it
3. You should see your Foundry account, smoke project, and AI Search service
4. Open `rg-klzfin-platform-dev` to see Log Analytics, App Insights, Key Vault, Data Collection Rules, and 2 workbooks

### Open a workbook

1. In `rg-klzfin-platform-dev` → click on a workbook (the items with long GUID names of type **Microsoft.Insights/workbooks**)
2. Workbook will load empty (no traffic yet) — that's expected. You're confirming the **shape** works, not the data.

---

## Part 6 — Tear it all down (important — do this within ~1 hour to keep cost <$1)

```powershell
./scripts/deploy.ps1 -Mode teardown -Workload klzfin -Environment dev
```

The script runs in **3 phases** to avoid an orphan-SAL deadlock that can otherwise pin the spoke VNet for 30-60+ min after `enableFoundryAgentInjection=true` deploys:

1. **Pre-release** — DELETE the agent capability host (`capabilityHosts/default`) on every Foundry account in the RG, then delete every `Microsoft.App/managedEnvironments` (CAE). This releases the `legionservicelink` Service Association Link that the agent service installs on `AIFoundrySubnet`.
2. **Foundry first** — delete the Foundry RG *synchronously*, then immediately `cognitiveservices account purge` the soft-deleted account, then kick off the platform + hub RG deletes in parallel.
3. **Poll** — up to 40 min for the platform RG (APIM StandardV2 + SAL settle is the long pole).

Verify after a few minutes:

```powershell
az group list --query "[?starts_with(name,'rg-klzfin')].name" -o table
```

If both/all groups are gone (or in `Deleting` state), you're done.

> **Soft-delete + cooldown notes:**
> - **Key Vault** stays soft-deleted for 7 days then auto-purges. Costs nothing.
> - **Microsoft Foundry (Cognitive Services)** also soft-deletes — the teardown script **auto-purges** it for you (now in phase 2, before the platform RG goes). If you ever see `FlagMustBeSetForRestore`, a stale soft-deleted Foundry is blocking you (see troubleshooting).
> - **AI Search** has a backend `ServiceDeleting` state that can linger ~2 minutes after the resource group is gone. If you teardown then immediately redeploy and hit `ServiceDeleting`, just wait 3 minutes and retry — same command.
> - **Orphan VNet + NSGs** — if the platform RG shows residual `Microsoft.Network/virtualNetworks` + NSGs after teardown finishes, the Microsoft.App RP cleanup hasn't released the SAL yet. **These resources cost $0/day** (no compute, no PaaS). Walk away — they auto-clean within 1-2 hours. Re-running teardown won't help (`az` is blocked from deleting SALs directly; only the owning RP can).

---

## Part 7 — What just got deployed (for your understanding)

| Layer | Resource | Why |
|---|---|---|
| **Foundry** | Microsoft Foundry account (Cognitive Services kind=AIServices) | The brain — hosts your AI projects |
| | `smoke` project (child of account) | Where teams build agents |
| | `gpt-4o-mini` model deployment | A real OpenAI model you can call |
| **Search** | AI Search Basic (westus2 due to eastus2 capacity) | Vector store for RAG |
| **Networking** | Spoke VNet `vnet-klzfin-dev-<suffix>` on `10.50.0.0/20` | The 9-subnet catalog (Stage A) |
| | `PrivateEndpointSubnet` (`10.50.0.0/24`) + `AIFoundrySubnet` (`10.50.1.0/24`) | Always-on baseline subnets |
| | 21 private DNS zones (vaultcore, openai, cognitiveservices, search, blob, …) | One per Azure PE-capable service, linked back to the spoke |
| | Foundry PE → 2 A records (`cognitiveservices.azure.com`, `openai.azure.com`) | Single PE resolves both zones — required for SDK |
| | Key Vault PE → `vaultcore.azure.net` | Private path to secrets |
| **Observability** | Log Analytics Workspace | Central log store |
| | Application Insights | App-level telemetry |
| | 2 custom log tables (PRICING_CL, SUBSCRIPTION_QUOTA_CL) | FinOps pricing + quota data |
| | Data Collection Endpoint + 2 Data Collection Rules | How custom data gets into the log tables |
| | Scheduled query alert (Fabric p95 latency) | Notifies you when AI calls get slow |
| | 2 workbooks (Agent Performance, FinOps Showback) | Dashboards |
| **Security** | Key Vault (purge protection on, soft-delete 7d) | For secrets/keys |
| | `disableLocalAuth=true` on Foundry | Forces Entra-ID auth, no API keys |

Everything is wired with **Azure Verified Modules (AVM)** — Microsoft's officially supported Bicep modules — so it's enterprise-grade out of the box. The smoke profile keeps APIM, App Gateway, Bastion, JumpVM, BuildVM, and the Container Apps Environment **off** via the `components` toggle bag in `infra/bicep/parameters/dev.bicepparam` — flip any of those to `deploy: true` to layer them in.

---

## Part 8 — When you want to do the full deploy (APIM + private networking)

When you're ready to deploy with APIM AI Gateway on top of the same Stage A baseline:

```powershell
./scripts/deploy.ps1 -Mode full -Workload klzfin -Environment dev -Location eastus2
```

This auto-picks `infra/bicep/parameters/full.bicepparam` (standalone networking + APIM StandardV2 in PE mode). It takes ~25 min and costs ~$45/day, dominated by APIM at ~$38/day. Tear down the same way. **Do this only after a successful smoke deploy.**

## Part 8b — When you want to wire into an existing hub (brownfield ALZ)

If your tenant already has a hub VNet + Azure Firewall + central Private DNS Zones, copy the sample and fill in your three values:

```powershell
Copy-Item infra/bicep/parameters/enterprise-hub-connected.sample.bicepparam `
          infra/bicep/parameters/enterprise-hub-connected.bicepparam
notepad infra/bicep/parameters/enterprise-hub-connected.bicepparam   # replace the <REPLACE> blocks

./scripts/deploy.ps1 -Mode smoke -Workload klzfin -Environment dev `
  -ParameterFile infra/bicep/parameters/enterprise-hub-connected.bicepparam
```

The accelerator will create the spoke VNet, peer it to your hub, link your existing DNS zones back to the spoke, and (when `enableForcedTunneling=true`) attach a UDR routing 0.0.0.0/0 through your hub firewall. Day-0 recommendation: keep `enableForcedTunneling=false` until you've validated DNS + peering, then flip it on. See `docs/hub-spoke-integration.md` for the full runbook.

---

## Enforcing the APIM chokepoint

By default the accelerator deploys APIM AI Gateway as a **recommended** hop, but Foundry's public endpoint stays open to anyone with `Cognitive Services User` RBAC. To make APIM the **only** path into Foundry/Search, flip one parameter.

**Bicep:**

```bicep
// in your blueprint .bicepparam (e.g., prod-hub-connected — already set there)
param enforceApimChokepoint   = true
param allowAgentSubnetBypass  = true   // default; required when foundry agent injection is on
param allowCaeBypass          = false  // turn on only if first-party CAE apps must bypass APIM
```

**Terraform:**

```hcl
# in your blueprint .tfvars
enforce_apim_chokepoint   = true
allow_agent_subnet_bypass = true   # default; required when foundry agent injection is on
allow_cae_bypass          = false  # turn on only if first-party CAE apps must bypass APIM
```

**What it changes** (the build/plan will fail-fast if any precondition is unmet):

| Resource | Property | After |
|---|---|---|
| Foundry account | `publicNetworkAccess` | `Disabled` |
| Standalone AI Search | `publicNetworkAccess` / `disableLocalAuth` | `Disabled` / `true` |
| Standalone AI Search | private endpoint | created (was missing) |
| `PrivateEndpointSubnet` | `privateEndpointNetworkPolicies` | `NetworkSecurityGroupEnabled` |
| `PrivateEndpointSubnet` NSG | 5 rules added | Allow `APIMSubnet→443`, Allow LB, optional Allow Agent/CAE, **Deny all** at 4096 |

**Preconditions** (deployment refuses to apply if violated):

1. `components.apim.deploy = true`
2. `components.apim.networkMode ∈ {external, internal}`
3. If `components.standaloneSearch.deploy = true`, then `searchLocation == location`

**Post-deploy verification (~3 minutes):**

```powershell
# 1) Foundry should reject public hits with 403 Forbidden after a network ACL change
$endpoint = az cognitiveservices account show -n aif-<your-suffix> -g rg-<workload>-foundry-<env> --query properties.endpoint -o tsv
curl -i "$endpoint/openai/models?api-version=2024-10-21" -H "api-key: anything"
# Expected: 403 PublicNetworkAccessDisabled

# 2) The same call routed via APIM should succeed (200 + model list)
$apim = az apim show -n apim-<your-suffix> -g rg-<workload>-platform-<env> --query gatewayUrl -o tsv
curl -i "$apim/openai/models?api-version=2024-10-21" -H "Ocp-Apim-Subscription-Key: <product-key>"
# Expected: 200 OK + list of deployed models

# 3) Confirm the deny rule is in effect on the PE subnet
$nsg = az network nsg show -g rg-<workload>-platform-<env> -n nsg-PrivateEndpointSubnet-<suffix> --query "securityRules[?name=='Deny-AllOther-Inbound']" -o table
# Expected: 1 row, priority 4096, Deny all
```

**Blueprint defaults:**

| Blueprint | `enforceApimChokepoint` |
|---|---|
| `smoke` | `false` (no APIM in this blueprint) |
| `poc-standalone-spoke` | `false` |
| `poc-hub-connected` | `false` |
| `prod-standalone-with-fw` | `false` (operator may need direct PE for Power Platform / Logic Apps) |
| **`prod-hub-connected`** | **`true`** (recommended enterprise default) |

**When to leave it OFF:**
- During initial bring-up (turn on after APIM is healthy and you've cut a product/subscription key)
- If you have Logic Apps / Power Platform / on-prem callers that hit Foundry directly without going through APIM
- For dev/sandbox environments where token-limit + content-safety policies are noise

---

## Verifying APIM AI Gateway end-to-end (after a `prod-*` deploy)

Once your full deploy is green, run the live policy validation. This is the same script-equivalent we used to validate every policy in the chain.

### 1. Grab the APIM subscription key (StandardV2 quirk)

`az apim subscription keys list --sid master` returns empty for StandardV2. Use the REST endpoint:

```powershell
$apim = 'apim-klzfin-prod-<suffix>'
$rg = 'rg-klzfin-platform-prod'
$sub = (az account show --query id -o tsv)
$path = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/subscriptions/master/listSecrets?api-version=2024-05-01"
$keyJson = az rest --method POST --uri "https://management.azure.com$path" --headers "Content-Length=0"
$key = ($keyJson | ConvertFrom-Json).primaryKey
$gw = az apim show -n $apim -g $rg --query gatewayUrl -o tsv
```

### 2. Smoke the chain

```powershell
# T1 — first call should succeed and populate the semantic cache
curl -s -X POST "$gw/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-02-01" `
  -H "Content-Type: application/json" `
  -H "Ocp-Apim-Subscription-Key: $key" `
  -H "x-project: smoke-test" `
  -H "x-use-case: validation" `
  -H "x-cost-center: cc-platform" `
  -d '{"messages":[{"role":"user","content":"What is 2 plus 2?"}],"max_tokens":50}'
# Expected: 200 OK, full chat response, non-empty body, tokens > 0
```

```powershell
# T2 — repeat identical prompt within 1 hour — should be served from cache (faster)
# Same curl as T1 — measure the latency drop
```

### 3. What "working" looks like

| What | Where to check | Expected |
|---|---|---|
| Body is non-empty | Response | Full `choices[0].message.content` with model output |
| `azure-openai-emit-token-metric` is firing | App Insights → `customMetrics` table | Rows with `ProjectName=smoke-test`, `UseCase=validation`, `CostCenter=cc-platform` |
| Semantic cache is storing | T2 vs T1 latency | T2 ~30-50% faster (no backend hit) |
| Token-limit is counting | After many calls, response header | `x-azure-openai-tokens-consumed` value climbs; 429 after `productTokensPerMinute` |
| Managed-identity backend auth works | No `api-key` header on backend call | Visible in APIM diagnostic logs (`AzureDiagnostics` → `ApiManagementGatewayLogs`) |

### 4. Common findings

- **200 OK but `Content-Length: 0`** → see [README — Configuration note (1)](../README.md#configuration-note-1--global-backend--must-be-explicit). The global `<backend />` element is missing `<forward-request />`. Already correct in `apim-policies/inbound-emit-metrics.xml` — verify the file on disk matches.
- **403 "Request failed content safety check" on every prompt** → was a missing `credentials.managedIdentity.resource` on the `content-safety-backend`. Both Bicep and Terraform now configure the MI credentials per [Microsoft's llm-content-safety policy reference](https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy). If you still see this on a fresh deploy, confirm APIM MI has the **Cognitive Services User** role on the Foundry account (granted by `apim-foundry-rbac.bicep`).

### 5. Automated re-run

The full validation above is encoded in `scripts/smoke-policies.ps1` — run it any time you want a 90-second sanity check on a live deploy:

```powershell
./scripts/smoke-policies.ps1 -Workload klzfin -Env prod -SubscriptionId <your-sub-id>
```

It exercises all six policies (auth, forward-request regression, semantic cache, token-limit, emit-metric, content-safety), queries App Insights to confirm metrics arrived, and emits a pass/warn/fail table. Use `-StrictContentSafety` to require the content-safety check pass (now fixed in code; default is informational pending live re-validation in your tenant). Use `-ExpectApim` to fail (rather than skip) when no APIM is found — useful for CI on blueprints that should always have APIM enabled.

---

## Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `az : The term 'az' is not recognized` | CLI not on PATH | Close + reopen terminal after install |
| `Please run 'az login'` | Not signed in | `az login` |
| `AuthorizationFailed` | Account lacks Contributor | Ask Azure admin for the role |
| `InsufficientResourcesAvailable` on Search | Region capacity exhausted | Edit `dev.bicepparam` → change `searchLocation` to `eastus` or `westus3` |
| `InsufficientResourcesAvailable` on AKS GPU SKUs (agent injection) | eastus2 GPU quota exhausted | Set `enableFoundryAgentInjection = false` in the blueprint or change `location` |
| `FlagMustBeSetForRestore` on Foundry account | Soft-deleted Foundry from a prior teardown is still around (48h retention) | `az cognitiveservices account purge --location eastus2 --resource-group rg-klzfin-foundry-dev --name aif-klzfin-dev-<suffix>` then retry |
| `ServiceDeleting` / `Cannot provision service named 'srch-...'` | AI Search backend is still cleaning up from a prior teardown | Wait 3 minutes, then re-run the same deploy command |
| `InUseSubnetCannotBeDeleted ... serviceAssociationLinks/legionservicelink` | Foundry agent injection installed a SAL on `AIFoundrySubnet`; CAE deleted but the orphan SAL hasn't been reaped by Microsoft.App RP yet | **Wait 1-2 hours** — the RP cleanup pass releases the SAL automatically. `az` is blocked from deleting SALs directly (Microsoft.App owns them). Residual VNet+NSGs cost $0/day. |
| `az rest ... 'UnauthorizedClientApplication ... 04b07795-8ddb-461a-bbee-02f9e1bf7b46'` on a serviceAssociationLinks DELETE | Azure CLI is explicitly blocked from deleting SALs (security boundary) | Same as above — wait for the owning RP to reap |
| APIM returns `HTTP 200` with **empty body** for every chat completion | Global policy has self-closing `<backend />` instead of `<backend><forward-request /></backend>` | Edit `apim-policies/inbound-emit-metrics.xml` — see [README — Configuration note (1)](../README.md#configuration-note-1--global-backend--must-be-explicit) |
| APIM returns `403 "Request failed content safety check"` for ALL prompts (even "what is 2+2?") | `content-safety-backend` is missing `credentials.managedIdentity.resource = "https://cognitiveservices.azure.com"` (per [Microsoft docs](https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy)) | Configured in both Bicep (`apim-ai-api.bicep`) and Terraform (`modules/apim/main.tf`). Re-deploy and re-run `scripts/smoke-policies.ps1 -StrictContentSafety`. |
| `az apim subscription keys list --sid master` returns empty for StandardV2 | StandardV2 doesn't surface keys via this CLI command | Use the REST endpoint: `POST /subscriptions/master/listSecrets?api-version=2024-05-01` (with explicit `Content-Length: 0` header). Helper in `scripts/smoke-verify.ps1`. |
| APIM StandardV2 has no `publicIpAddresses` / `outboundPublicIPAddresses` | StandardV2 doesn't expose VIPs; can't IP-allowlist | Use `enforceApimChokepoint = true` (PE-only Foundry); don't combine StandardV2 + PNA=Enabled + Foundry IP allowlist |
| The workspace could not be found on alerts | Cascade from an earlier failure in the same deploy | Re-run the deploy after fixing the root error |
| `Failed to resolve scalar expression` on alert | KQL targets a table that doesn't exist | This is already gated behind `mode=full`; should not hit in smoke |
| Stuck for >10 min | Network or Azure backend | Open another terminal: `az deployment sub list --query "[?starts_with(name,'klz-')].{name:name, state:properties.provisioningState}" -o table` |
| `az rest` chokes on `'charmap' codec can't encode character '\ufeff'` | UTF-8 BOM in response confuses Python on Windows | Use `curl.exe --output-file response.json` instead of `az rest`, then parse the file |
| Need to start over | Anything weird | Run teardown, wait 5 min, re-deploy |

---

## Questions / support

If you get stuck, please open a GitHub issue with:
1. The exact command you ran
2. The full error output
3. Output of `az account show -o table`

We can usually unblock you in one round-trip.

— Platform Team
