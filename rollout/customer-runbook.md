# KLZ rollout runbook — the customer

This runbook takes the customer from "accelerator installed" to "AI Landing Zone MG
governed by the KLZ baseline initiative with notifications wired into Teams."

**Read end-to-end first. Do not skip steps.**

---

## Part 0 — Pre-reqs (one-time, ~10 min)

the customer needs:

- **Tooling**: az CLI >= 2.60.0, PowerShell 7+, PowerShell module `Az` (>= 12.0).
- **Permissions** (at minimum):
  - `Owner` or `Management Group Contributor` at his existing Platform MG.
  - `Owner` or `Contributor` on the Azure subscription that hosts Foundry.
  - `Resource Policy Contributor` at the Platform MG (to publish defs + assign).
- **Azure resources** that must already exist:
  - An intermediate Platform MG (e.g. `mg-corp-platform`) under the tenant root.
  - A Log Analytics workspace in the Foundry subscription (the policy initiative
    will deploy diagnostic-settings into it).

If any of those are missing, fix them before continuing.

---

## Part 1 — Fill in `config/customer.psd1` (one-time, ~5 min)

```powershell
cd <repo-root>\rollout
Copy-Item .\config\customer.psd1.template .\config\customer.psd1
notepad .\config\customer.psd1   # or your editor
```

Required fields:

| Field | Where to find it |
|-------|------------------|
| `TenantId` | `az account show --query tenantId -o tsv` |
| `SubscriptionId` | The sub that hosts the Foundry account |
| `ParentManagementGroupId` | Your existing Platform MG's `name` (NOT display name) |
| `LogAnalyticsWorkspaceId` | `az monitor log-analytics workspace show -g <rg> -n <name> --query id -o tsv` |
| `ResourceGroupsToMove` | Names of the RGs that hold Foundry, AI Search, APIM (so they inherit the policy) |
| `PolicyEffect` | Start at `Audit`. Switch to `Deny` only after a clean baseline. |

Optional (Phase B.4 — fill when you're ready):

| Field | Notes |
|-------|-------|
| `DeployNotifications` | Set `$true` to provision the Logic App. |
| `EnableLogicApp` | Set `$true` to flip workflow state to Enabled. |
| `TeamsWebhookUrl` | Or pass at runtime via `-TeamsWebhookUrl` flag — recommended so it's not on disk. |

---

## Part 2 — Run preflight (~2 min)

```powershell
cd <repo-root>\rollout\scripts
pwsh -File .\00-preflight.ps1 -ConfigPath ..\config\customer.psd1
```

You must see **Preflight PASSED**. If any FAIL line appears, fix it before
moving on. The script does not call any change-making API; it's safe to
re-run.

---

## Part 3 — Create the AI Landing Zone MG (~1 min)

Always do a dry run first:

```powershell
pwsh -File .\10-mg-hierarchy-ensure.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
pwsh -File .\10-mg-hierarchy-ensure.ps1 -ConfigPath ..\config\customer.psd1
```

This creates `ai-landing-zone` under your parent MG. Idempotent — no-op on
second run if it already exists with the correct parent.

---

## Part 4 — Move subscriptions under the new MG (~1 min)

> **Caution**: this moves the **entire subscription** (not just the Foundry
> RGs) under `ai-landing-zone`. Every RG in that sub will inherit the policy
> assignments from Part 5. Start with effect=Audit so nothing is blocked.

```powershell
pwsh -File .\15-subscription-move-under-mg.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
pwsh -File .\15-subscription-move-under-mg.ps1 -ConfigPath ..\config\customer.psd1
```

---

## Part 5 — Publish + assign the policy initiative (~2 min + 30 min for first eval)

```powershell
# Always dry run first (this is just a wrapper but the inner script defaults to DryRun=$true)
pwsh -File .\20-mg-policy-assign.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf

# Actual assignment (effect = whatever customer.psd1 says — default Audit)
pwsh -File .\20-mg-policy-assign.ps1 -ConfigPath ..\config\customer.psd1
```

What this publishes at `mg = ai-landing-zone`:

- 5 custom policy definitions (klz-require-tags, klz-require-cost-tags,
  klz-cognitive-model-allowlist, klz-cognitive-private-only,
  klz-defender-for-ai-dine)
- 1 initiative `foundry-enterprise-baseline` referencing 12 built-in policies
  plus the 5 custom defs above
- 1 assignment of the initiative at the MG with SystemAssigned identity
  (needed for the DeployIfNotExists policy on diagnostic settings)

**Wait 30 minutes**, then export compliance:

```powershell
az policy state summarize --management-group ai-landing-zone -o table
az policy state list --management-group ai-landing-zone --filter "complianceState eq 'NonCompliant'" -o table
```

If you see violations on resources you didn't create, that is the BASELINE
GAP — fix the resources, do **not** flip to Deny until this list is empty.

---

## Part 6 — Enable Teams notifications (~5 min, optional)

1. In Teams: open the channel you want alerts in -> `…` -> Workflows -> "Post
   to a channel when a webhook request is received" -> copy the URL.
2. Run:
   ```powershell
   pwsh -File .\30-notifications-enable.ps1 `
       -ConfigPath ..\config\customer.psd1 `
       -TeamsWebhookUrl 'https://<tenant>.webhook.office.com/...'
   ```
3. Wire your Action Groups to call the Logic App trigger URL (one-time per AG):
   ```powershell
   # Get the trigger URL
   $wfId = az resource show --ids "/subscriptions/<sub>/resourceGroups/rg-<workload>-platform-<env>/providers/Microsoft.Logic/workflows/logic-notif-<workload>-<env>-<suffix>" --query id -o tsv
   az rest --method post --uri "$wfId/triggers/manual/listCallbackUrl?api-version=2019-05-01"
   ```
   Configure the Action Group's webhook destination = that callback URL.

---

## Part 7 — Switch to Deny mode (after >= 1 week of clean Audit)

```powershell
# Edit customer.psd1 -> change PolicyEffect = 'Deny'
pwsh -File .\20-mg-policy-assign.ps1 -ConfigPath ..\config\customer.psd1
# Script will require you to type the literal word DENY to proceed.
```

---

## Part 8 — Rollback (emergency)

Reverses Parts 3-6 in one shot:

```powershell
pwsh -File .\99-rollback-all.ps1 -ConfigPath ..\config\customer.psd1 -WhatIf
pwsh -File .\99-rollback-all.ps1 -ConfigPath ..\config\customer.psd1
```

Removes: policy assignments, initiative, custom defs, AI Landing Zone MG,
re-parents the moved subscriptions back to your original parent MG.

---

## What's NOT in this rollout (yet)

- Phase C — Conditional Access, DLP, Defender for Cloud Apps shadow-AI tagging.
  Design lives in `scripts/40-shadow-ai-ca.ps1`; we'll iterate after we see
  how the policy initiative behaves in your tenant.

## When something goes wrong

1. Run `99-rollback-all.ps1 -WhatIf` first to confirm what would be removed.
2. Capture `Get-AzPolicyAssignment` / `az policy assignment list --scope <mg>`
   output and send it to the maintainer.
3. Default to "leave as-is in Audit, investigate, fix, re-run." Audit never
   breaks anything.
