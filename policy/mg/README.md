# Management Group scaffolding for Phase B

This folder creates the **AI Landing Zone** MG so that the Foundry
Enterprise Baseline initiative ([../initiative/foundry-enterprise-baseline.json](../initiative/foundry-enterprise-baseline.json))
has a real scope to attach to. Per **D2 decision (2026-05-25)**:

| Item | Value |
|---|---|
| New MG | `ai-landing-zone` (display: "AI Landing Zone") |
| Parent | An existing intermediate Platform MG (caller supplies the ID) |
| New subscription | `sub-ai-platform-dev` (not yet provisioned — see "Sub creation" below) |
| Rollout mode | **Audit-first** (per cybersec sign-off) |

## What this Bicep does

- Creates a single `Microsoft.Management/managementGroups` resource at tenant
  scope under the parent you specify.
- That's it. No policy attached, no subscription moved. Reversible by deleting
  the MG (which is itself a single ARM delete).

## Prerequisites

| Item | Who/where |
|---|---|
| `Management Group Contributor` on the parent (Platform) MG | Caller's identity. Tenant Root requires Owner; an intermediate MG only needs `Management Group Contributor`. |
| The parent MG ID | Hand-supplied as `parentManagementGroupId`. Find it via `az account management-group list --query "[].{id:id,name:name}" -o table`. |
| Az CLI logged in to the right tenant | `az login --tenant <tenantId>` |

## Deploy

```powershell
# 1. Find the parent Platform MG id
az account management-group list --query "[].{id:name, display:displayName}" -o table

# 2. Preview (what-if)
az deployment tenant what-if `
  --location eastus2 `
  --template-file policy/mg/main.bicep `
  --parameters parentManagementGroupId=<platform-mg-id>

# 3. Deploy
az deployment tenant create `
  --name "klz-mg-ailz-$(Get-Date -Format yyyyMMddHHmm)" `
  --location eastus2 `
  --template-file policy/mg/main.bicep `
  --parameters parentManagementGroupId=<platform-mg-id>
```

## Sub creation (`sub-ai-platform-dev`)

Subscription creation is **not in this Bicep** because it requires one of:

- **EA enrollment account** + `Microsoft.Subscription/createSubscription` permission, or
- **MCA billing scope** + `SubscriptionCreator` role on a billing profile.

Most engineering identities do not hold these roles, so the standard pattern is:

1. **Open a request to the billing/EA admin** for a new subscription named
   `sub-ai-platform-dev` and ask them to **move it under the `ai-landing-zone`
   MG** as soon as it lands (default landing is Tenant Root).
2. While waiting, the dev environment continues to run in the current
   subscription (`22222222-2222-2222-2222-222222222222`) — Phase A.5 / A.5b / B.1
   are all live there. Policy assignment can run against the current sub as a
   stand-in by moving the current sub under the new MG temporarily, or by
   skipping the MG path and assigning at sub scope.
3. Once `sub-ai-platform-dev` exists, capture its GUID into
   [../../placeholders/azure-targets.template.md](../../placeholders/azure-targets.template.md)
   and re-run [../assign-mg-initiative.ps1](../assign-mg-initiative.ps1) with
   the real values.

## After the MG exists — next step

Hand the MG ID (it's lowercase, no spaces, e.g. `ai-landing-zone`) to:

```powershell
# Still DryRun by default — read it first, then re-run with -DryRun:$false
./policy/assign-mg-initiative.ps1 `
  -ManagementGroupId        ai-landing-zone `
  -SubscriptionId           22222222-2222-2222-2222-222222222222 `
  -LogAnalyticsWorkspaceId  "/subscriptions/.../workspaces/log-klzfin-dev-c6ej" `
  -Mode                     Audit
```

`Mode = Audit` is the cybersec-signed-off starting point. Promotion to `Deny`
is gated behind a second sign-off and the `-Confirm` prompt baked into the
script.

## Rollback

```powershell
# 1. Move any subs back to the parent MG
az account management-group subscription remove --name ai-landing-zone --subscription <subId>

# 2. Delete the MG
az account management-group delete --name ai-landing-zone
```
