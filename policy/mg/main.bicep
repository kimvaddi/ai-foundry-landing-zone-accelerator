// =============================================================================
//  KLZ — Management Group hierarchy for the AI Landing Zone
// -----------------------------------------------------------------------------
//  Scope     : managementGroup (the PARENT Platform MG)
//  Purpose   : Create the "AI Landing Zone" MG under an existing intermediate
//              Platform MG, so the Foundry Enterprise Baseline initiative
//              (policy/initiative/foundry-enterprise-baseline.json) has a
//              real scope to attach to.
//  Safety    : MG creation is reversible (Move-AzManagementGroup or portal).
//              No policy assignment happens here — that is owned by
//              policy/assign-mg-initiative.ps1 which still defaults to DryRun.
//
//  Deploy    : az deployment mg create \
//                --management-group-id <parent-mg-id> \
//                --name klz-mg-ailz-$(Get-Date -Format yyyyMMddHHmm) \
//                --location eastus2 \
//                --template-file policy/mg/main.bicep \
//                --parameters parentManagementGroupId=<parent-mg-id> \
//                             aiLandingZoneManagementGroupId=<new-mg-id> \
//                             aiLandingZoneDisplayName=<display>
//
//  Why managementGroup scope (not tenant): deploying at tenant scope requires
//  Owner / Contributor at the Tenant Root MG itself, which is rarely granted
//  even to tenant admins (must go through 'Elevate access'). Deploying at the
//  PARENT MG scope only requires 'Management Group Contributor' at that MG,
//  which is the natural permission for whoever owns the Platform MG.
//
//  Prereqs   : Caller must hold 'Management Group Contributor' at the parent
//              (Platform) MG. Once created, grant 'Resource Policy Contributor'
//              on the new MG to whoever will run assign-mg-initiative.ps1.
// =============================================================================

targetScope = 'managementGroup'

@description('MG ID of the existing intermediate Platform MG that will be the parent of the new AI Landing Zone MG. e.g. "platform-mg" or "mg-platform". DO NOT include the /providers/... prefix. Must match the --management-group-id passed to `az deployment mg create`.')
param parentManagementGroupId string

@description('MG ID for the new AI Landing Zone container. Must be unique tenant-wide, lowercase, no spaces. Default matches D2 decision.')
param aiLandingZoneManagementGroupId string = 'ai-landing-zone'

@description('Display name shown in the portal.')
param aiLandingZoneDisplayName string = 'AI Landing Zone'

// -----------------------------------------------------------------------------
//  The MG itself — created as a tenant-level resource from the parent MG scope
// -----------------------------------------------------------------------------
resource aiLandingZoneMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  scope: tenant()
  name: aiLandingZoneManagementGroupId
  properties: {
    displayName: aiLandingZoneDisplayName
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', parentManagementGroupId)
      }
    }
  }
}

// -----------------------------------------------------------------------------
//  Outputs — feed straight into assign-mg-initiative.ps1 -ManagementGroupId
// -----------------------------------------------------------------------------
output managementGroupId   string = aiLandingZoneMg.name
output managementGroupName string = aiLandingZoneMg.properties.displayName
output managementGroupArmId string = aiLandingZoneMg.id
