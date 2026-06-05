# Placeholders for the adopting organization to fill in

This folder holds **the three external inputs** the accelerator needs
before it can actually deploy into a target tenant. Everything else in
the repo is parameterised against these files so we never hard-code a
tenant-specific value into the IaC or policy artifacts.

Workflow:

1. **The repo** ships with the placeholder files in this folder, prefilled
   with realistic staging values (so reviews and dry-runs work end-to-end).
2. **The adopting organization** (or its platform owner) replaces the staging values
   with their real ones before any deploy.
3. The deploy scripts read these files — no other code changes needed.

| File | What it answers | Decision |
|---|---|---|
| [subscriptions.template.txt](subscriptions.template.txt) | Which subscriptions does brownfield discovery scan? | D3 |
| [azure-targets.template.md](azure-targets.template.md) | Which MG + sub does Phase B attach to? | D2 |
| [stakeholders.template.md](stakeholders.template.md) | Which humans approve / operate / get paged for Phase C? | D4 |

## Staging defaults (what ships in the repo today)

These are **made-up** values that let us validate end-to-end against a
local dev tenant. Replace them all before any production deploy.

| Placeholder | Staging default | What it is |
|---|---|---|
| Sub for brownfield discovery | `22222222-2222-2222-2222-222222222222` | Our own dev sub (real) |
| Target MG | `ai-landing-zone` under parent `<platform-mg-id>` | Target name, MG itself not yet created |
| Target sub | `sub-ai-platform-dev` | Target name, sub not yet provisioned |
| IAM owner email | `iam-team@contoso.example` | Stamped into CA policies |
| SecOps owner email | `secops@contoso.example` | Stamped into MCAS runbook + alerts |
| Compliance owner email | `compliance@contoso.example` | Stamped into Purview DLP + audit |

## How the scripts consume these files

```text
scripts/brownfield-discover.ps1
   └─ reads placeholders/subscriptions.template.txt → -SubscriptionIds

policy/assign-mg-initiative.ps1
   └─ -ManagementGroupId, -SubscriptionId values come from
      placeholders/azure-targets.template.md (operator copy-paste)

governance/shadow-ai/ca-policies/*.json
governance/shadow-ai/purview-dlp/*.json
governance/shadow-ai/mcas-connectors.md
   └─ owner/approver emails come from placeholders/stakeholders.template.md
      via search-and-replace before MgGraph apply.
```

> The `@contoso.example` addresses in the placeholder files are Microsoft-style example
> values (RFC 2606 reserves `example` for documentation). Replace them with real
> addresses for your organization before deploying — they are not customer references.
