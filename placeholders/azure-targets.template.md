# Azure scope targets

> **Status:** target names only. Neither the MG nor the subscription exist yet.
> The platform/billing admin creates them; then drop the real IDs back into
> the table below and re-run the assignment script.

## Targets

| Item | Target | Status |
|---|---|---|
| New MG | `ai-landing-zone` (display: "AI Landing Zone") | **Not yet created** |
| Parent MG | An existing intermediate Platform MG | **ID needed from the platform admin** |
| New subscription | `sub-ai-platform-dev` | **Not yet provisioned** |
| Rollout mode | Audit-first | **Default** |

## Fill these in once the resources exist

```text
PARENT_PLATFORM_MG_ID        = <e.g. mg-platform>
AI_LANDING_ZONE_MG_ID        = ai-landing-zone           # default in Bicep
AI_LANDING_ZONE_MG_ARM_ID    = /providers/Microsoft.Management/managementGroups/ai-landing-zone

NEW_SUB_NAME                 = sub-ai-platform-dev
NEW_SUB_GUID                 = <fill once provisioned>

DEV_LAW_RESOURCE_ID          = /subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>
```

## Sequence

1. **Confirm the parent Platform MG ID** → fill `PARENT_PLATFORM_MG_ID`.
2. **Create the new MG** with [../policy/mg/main.bicep](../policy/mg/main.bicep):
   ```powershell
   az deployment tenant create `
     --name "klz-mg-ailz-$(Get-Date -Format yyyyMMddHHmm)" `
     --location eastus2 `
     --template-file policy/mg/main.bicep `
     --parameters parentManagementGroupId=<PARENT_PLATFORM_MG_ID>
   ```
3. **Request the new subscription** through EA/MCA, ask for it to be moved
   under the `ai-landing-zone` MG. While waiting, an existing dev sub can act
   as a stand-in.
4. **DryRun the assignment** (no writes):
   ```powershell
   ./policy/assign-mg-initiative.ps1 `
     -ManagementGroupId       ai-landing-zone `
     -SubscriptionId          <sub-guid> `
     -LogAnalyticsWorkspaceId "$DEV_LAW_RESOURCE_ID"
   ```
5. **Real assignment in Audit mode** (still no blocks, only signals):
   ```powershell
   ./policy/assign-mg-initiative.ps1 `
     -ManagementGroupId       ai-landing-zone `
     -SubscriptionId          $NEW_SUB_GUID `
     -LogAnalyticsWorkspaceId "$DEV_LAW_RESOURCE_ID" `
     -Mode                    Audit `
     -DryRun:$false
   ```
6. **Compliance evidence after ~30 min**:
   ```powershell
   ./scripts/policy-compliance-report.ps1 -ManagementGroupId ai-landing-zone
   ```
