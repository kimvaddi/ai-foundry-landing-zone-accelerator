<#
.SYNOPSIS
    Grants a runtime principal 'Monitoring Metrics Publisher' on the agent-audit
    DCR so klz_client.py can post rows to KlzAgentAudit_CL via Logs Ingestion API.

.PARAMETER PrincipalId
    Object ID of the runtime identity (managed identity, service principal, or user).
    REQUIRED — no default. The Monitoring Metrics Publisher role definition GUID
    happens to be 3913510d-42f4-4e42-8a64-420c390055eb; do not use that here.

.PARAMETER PrincipalType
    'ServicePrincipal' (default — covers system-assigned and user-assigned MIs and SPs)
    or 'User' for a developer's Entra user object id during local E2E testing.

.PARAMETER SubscriptionId
    Subscription where the platform RG lives.

.PARAMETER ResourceGroup
    Name of the platform resource group that holds the DCR.

.PARAMETER DcrName
    Name of the agent-audit DCR. Defaults to the name emitted by custom-tables.bicep
    in the dev landing zone.

.EXAMPLE
    # Grant a system-assigned MI
    .\grant-runtime-rbac.ps1 -PrincipalId 1234abcd-...

.EXAMPLE
    # Grant the current developer (for local E2E test only)
    $me = az ad signed-in-user show --query id -o tsv
    .\grant-runtime-rbac.ps1 -PrincipalId $me -PrincipalType User
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PrincipalId,

    [ValidateSet('ServicePrincipal','User','Group')]
    [string] $PrincipalType = 'ServicePrincipal',

    [string] $SubscriptionId = '22222222-2222-2222-2222-222222222222',
    [string] $ResourceGroup  = 'rg-klzfin-platform-dev',
    [string] $DcrName        = 'dcr-agent-audit-log-klzfin-dev-c6ej'
)

$ErrorActionPreference = 'Stop'

# Reject the well-known role GUID for Monitoring Metrics Publisher — it is NOT a principal id.
if ($PrincipalId -eq '3913510d-42f4-4e42-8a64-420c390055eb') {
    throw "PrincipalId '$PrincipalId' is the role definition GUID for 'Monitoring Metrics Publisher', not a principal object id. Pass the runtime identity's object id instead."
}

Write-Host "==> Setting subscription context: $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Resolving DCR resource ID..."
$dcrId = az monitor data-collection rule show `
    --name $DcrName `
    --resource-group $ResourceGroup `
    --query id -o tsv

if (-not $dcrId) { throw "DCR '$DcrName' not found in RG '$ResourceGroup' (sub $SubscriptionId)." }
Write-Host "    $dcrId"

Write-Host "==> Assigning 'Monitoring Metrics Publisher' to $PrincipalType $PrincipalId on DCR..."
$existing = az role assignment list `
    --assignee-object-id $PrincipalId `
    --scope $dcrId `
    --role 'Monitoring Metrics Publisher' `
    --query "[].id" -o tsv

if ($existing) {
    Write-Host "    Already assigned. Skipping." -ForegroundColor Yellow
} else {
    az role assignment create `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type $PrincipalType `
        --scope $dcrId `
        --role 'Monitoring Metrics Publisher' | Out-Null
    Write-Host "    [OK] Assignment created." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Principal can now POST to the DCR ingestion endpoint:"
Write-Host "    https://dce-log-klzfin-dev-c6ej-at88.eastus2-1.ingest.monitor.azure.com"
Write-Host "    stream: Custom-KlzAgentAudit_CL"
Write-Host "    DCR immutable id: dcr-6a419375c8d543748e1a9f98188766dd"

