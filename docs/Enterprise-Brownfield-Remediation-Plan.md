# KLZ Enterprise Brownfield Remediation Plan

> A 9-step playbook for retrofitting the KLZ governance + FinOps controls
> onto an existing Azure estate. This is the path most enterprise customers
> will take — landing zones already exist, Foundry / OpenAI accounts already
> exist, agents are already in some form of production, and you must
> instrument them **without** breaking workloads.

**Audience:** Platform engineering + cloud security + FinOps leads.

**Inputs you'll need on hand:**
* Subscription IDs in scope.
* Management group hierarchy export.
* `costCenter` ↔ workload mapping from finance.
* Existing CA / DLP / Defender policy inventory.

## Hub-connected W4 (private endpoints) is one-shot

The Stage A networking refactor added `networkMode='hub-connected'` to
`main.bicep`. If your tenant already runs a CAF/ALZ-style hub with central
Azure Firewall and central Private DNS Zones, the spoke side of W4 is a
single deploy:

1. Copy `infra/bicep/parameters/enterprise-hub-connected.sample.bicepparam`.
2. Replace the three `<REPLACE>` blocks (`hubVnetResourceId`,
   `hubFirewallPrivateIp`, `existingPrivateDnsZones` map).
3. Day-0: keep `enableForcedTunneling=false`, deploy, validate peering +
   DNS resolution.
4. Day-1: flip `enableForcedTunneling=true` once hub firewall rules are in
   place; the route table + UDR attach happens automatically.

This collapses the formerly-manual peering / DNS-link / UDR / NSG steps
into one Bicep deploy that's idempotent and easy to roll back via
`-Mode teardown` or by flipping `networkMode` back to `standalone`. See
`docs/hub-spoke-integration.md` for the full runbook and the manual
fallback procedures.

---

## 1. Discover

Run `./scripts/brownfield-discover.ps1 -SubscriptionIds <csv>` to
produce a snapshot CSV of every AI-relevant resource in scope.

The script reads via Azure Resource Graph (read-only) and exports:

* `out/brownfield-cogsvc.csv` — every Cognitive Services / Azure OpenAI / Foundry account, with publicNetworkAccess, disableLocalAuth, MI status, tag completeness.
* `out/brownfield-search.csv` — every AI Search service.
* `out/brownfield-apim.csv` — every API Management instance.
* `out/brownfield-rbac-gaps.csv` — accounts where local-key auth is still in use.
* `out/brownfield-tag-gaps.csv` — resources missing `costCenter`, `workload`, or `env`.

No writes. Safe to run any time.

## 2. Triage

Open `out/brownfield-cogsvc.csv` in Excel. Rank rows by:

1. `publicNetworkAccess == Enabled` AND `disableLocalAuth == false`  → **Critical** (publicly reachable with key auth).
2. `publicNetworkAccess == Enabled` AND `disableLocalAuth == true`   → **High**     (publicly reachable, MI-only).
3. `publicNetworkAccess == Disabled` AND `disableLocalAuth == false` → **Medium**   (private but key auth still possible).
4. Tag gaps with no security gap → **Low** (cost attribution only).

## 3. Plan retrofit waves

Most customers can NOT do this in one weekend. Suggested phasing:

| Wave | What | Window | Rollback |
|---|---|---|---|
| W1 | Apply Audit-mode policies tenant-wide (see `policy/assign-mg-initiative.ps1 -Mode Audit`). | 1 week. Zero blast radius. | Delete assignment. |
| W2 | Add cost-attribution tags. Add `klz:` tag prefix to every resource. | 2 weeks. | Tag removal. |
| W3 | Onboard one workload at a time onto APIM-fronted Foundry calls. Move from key auth → MI. | 1 workload/sprint. | Re-enable local auth temporarily; rollback connection string. |
| W4 | Migrate to private endpoints. | 1 workload/sprint. | DNS revert + re-enable publicNetworkAccess. |
| W5 | Promote policy to Deny ring-by-ring (sandbox → dev → prod). | 1 ring/week. | `policy/assign-mg-initiative.ps1` re-apply with `-Mode Audit`. |
| W6 | Enable Defender for AI Workloads (use the AINE def to surface coverage gaps first). | 1 week. | Set Defender pricing back to Free. |
| W7 | Enable shadow-AI report-only CA + Purview DLP. Run for 4 weeks. | 4 weeks. | Set state back to `disabled`. |
| W8 | Promote CA + DLP to enforced after CISO sign-off. | 1 week. | Same — flip state back. |
| W9 | Decommission shadow APIs that bypass APIM. | Long tail. | App owner re-codes for short term. |

## 4. Identity hygiene

Before W3 you MUST:

* Inventory all MIs / SPs that currently call Cognitive Services. The
  `brownfield-rbac-gaps.csv` lists every account whose access keys are
  still active.
* For each, plan the cut-over to either system-MI or workload-MI.
* Disable local auth ONE service at a time, watching `AzureDiagnostics`
  for `ResultType: Unauthorized` spikes.

## 5. Cost attribution backfill

The FOCUS export captures forward-going cost from the moment
you wire it up. For history:

1. Use the Azure Cost Management exports feature to backfill 13 months
   to your KLZ storage account.
2. The KQL workbook in `infra/bicep/modules/observability/workbooks.bicep`
   has a parameterised "as of" date — set it to your backfill window.
3. Where `costCenter` is missing, apply default `unattributed` and chase
   workload owners to backfill the tag.

## 6. APIM onboarding playbook (per workload)

1. Add a new API in `apim-policies/` for the workload (copy
   `policy.xml` template).
2. Add subscription key + JWT validation parameters per workload.
3. Add the chargeback `X-CostCenter` + `X-Project` headers as required
   inputs (matches `policies/headers.required.yaml`).
4. Switch the agent to point at APIM. Verify a few thousand requests in
   `AzureDiagnostics`.
5. Disable the direct Foundry endpoint via NSG / firewall.

## 7. Runtime onboarding

Each agent runtime that calls APIM should adopt
`governance/agent-runtime/runtime/klz_client.py`:

```python
from runtime import KlzClient
client = KlzClient.from_env(template_name="finops-default")
resp = client.invoke_chat_completion(payload, headers={
    "X-CostCenter": os.environ["COST_CENTER"],
    "X-Project":    os.environ["PROJECT"],
})
```

The client preflights against the YAML policy in
`governance/agent-runtime/policies/`, calls APIM, then writes an audit
row to LAW `KlzAgentAudit_CL` via the DCR from `custom-tables.bicep`.

## 8. Observability backfill

* Switch on Azure Monitor diagnostic settings for every Cognitive Services + APIM resource (the W1 initiative already enforces this DINE).
* Deploy the OTel collector (`infra/bicep/modules/observability/otel-collector.bicep`) once your Container Apps Environment is provisioned.
* Repoint agents at the internal OTLP endpoint.
* Verify traces in App Insights (`requests` table) + custom logs (`KlzAgentAudit_CL`).

## 9. Continuous improvement

Set a recurring cadence:

| Cadence | Activity | Owner |
|---|---|---|
| Daily | Review unresolved alerts from Action Group → Logic App fan-out. | On-call. |
| Weekly | Run `scripts/policy-compliance-report.ps1`. Trend non-compliant count. | Platform. |
| Weekly | Run `scripts/brownfield-discover.ps1` and diff vs last week. | Platform. |
| Monthly | Re-export DCA discovery and update `firewall-fqdn-allowlist.txt`. | Security. |
| Quarterly | Review the initiative's `allowedModels` parameter — add/remove models with AI council approval. | AI council. |
| Quarterly | Tabletop a shadow-AI incident using the CA + DLP report-only data. | Security + FinOps. |

---

## Cross-references

* `policy/initiative/foundry-enterprise-baseline.json` — the 16-control initiative referenced in W1 + W5.
* `governance/shadow-ai/` — the W7 + W8 controls (report-only by default).
* `infra/bicep/modules/finops/custom-tables.bicep` — the LAW tables (`PRICING_CL`, `SUBSCRIPTION_QUOTA_CL`, `KlzAgentAudit_CL`) that drive W8 reporting.
* `scripts/seed-pricing-table.ps1` — refreshes the `PRICING_CL` table from the public Azure Retail Prices API.
