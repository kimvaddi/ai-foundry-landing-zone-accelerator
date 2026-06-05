<#
.SYNOPSIS
    End-to-end deploy / teardown helper for the KLZ FinOps landing zone.

.DESCRIPTION
    Single entry point that wraps `az deployment sub` for the Bicep landing zone.
    -Mode whatif   : runs `az deployment sub what-if` only — no changes
    -Mode smoke    : minimal SKU baseline (cheap, ~$5/hr if forgotten)
    -Mode full     : full SKU baseline (APIM StandardV2, Foundry S0, AI Search S1)
    -Mode teardown : deletes the 5 RGs created by the LZ (klz-* prefix)

    Honors single-quoted JMESPath to work around the Windows az.cmd shim.

.EXAMPLE
    ./scripts/deploy.ps1 -Mode whatif
    Shows what would change without deploying.

.EXAMPLE
    ./scripts/deploy.ps1 -Mode smoke -Location eastus2
    Deploys the minimal SKU landing zone to eastus2.

.EXAMPLE
    ./scripts/deploy.ps1 -Mode teardown
    Removes the 5 klz-* RGs (use after a test run to stop billing).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('whatif', 'smoke', 'full', 'teardown')]
    [string] $Mode,

    [string] $Location = 'eastus2',
    [string] $Workload = 'klzfin',
    [string] $Environment = 'dev',
    [string] $ParameterFile
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
Set-Location $root

# Auto-pick param file by mode if not explicitly set
if (-not $ParameterFile) {
    $ParameterFile = switch ($Mode) {
        'full'  { 'infra/bicep/parameters/full.bicepparam' }
        default { 'infra/bicep/parameters/dev.bicepparam' }
    }
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# -------- Resource provider registration ------------------------------
# Idempotent: registers any RP that isn't already `Registered`, polls
# until every required RP reaches `Registered` state (or 5-min timeout).
# Subscription-scope ARM deployments will fail with NoRegisteredProviderFound
# the first time a brand-new sub touches a service (APIM diagnostics,
# Defender for AI, Policy Insights, etc.), so we front-load this.
function Ensure-Providers {
    param([string[]] $Required, [int] $TimeoutSeconds = 300)

    Write-Step "Ensuring resource providers are registered (${($Required.Count)} required)"

    # Kick off registration for anything not already Registered. `register`
    # is async; we poll below. Safe to call repeatedly.
    $pending = @()
    foreach ($rp in $Required) {
        $state = az provider show --namespace $rp --query 'registrationState' -o tsv 2>$null
        if (-not $state) {
            Write-Host "  ! $rp not visible on subscription — skipping (likely tenant-restricted)" -ForegroundColor DarkYellow
            continue
        }
        if ($state -ne 'Registered') {
            Write-Host "  + $rp (state=$state) → register" -ForegroundColor Yellow
            az provider register --namespace $rp --consent-to-permissions 2>$null | Out-Null
            $pending += $rp
        } else {
            Write-Host "  = $rp already Registered" -ForegroundColor DarkGray
        }
    }

    if ($pending.Count -eq 0) {
        Write-Host "All required providers already Registered." -ForegroundColor Green
        return
    }

    # Poll until every previously-pending RP reaches Registered.
    $waited = 0
    while ($waited -lt $TimeoutSeconds -and $pending.Count -gt 0) {
        Start-Sleep -Seconds 10
        $waited += 10
        $stillPending = @()
        foreach ($rp in $pending) {
            $state = az provider show --namespace $rp --query 'registrationState' -o tsv 2>$null
            if ($state -ne 'Registered') {
                $stillPending += $rp
            } else {
                Write-Host "  ✓ $rp now Registered after ${waited}s" -ForegroundColor Green
            }
        }
        $pending = $stillPending
        if ($pending.Count -gt 0) {
            Write-Host "  ... waiting on: $($pending -join ', ') (${waited}s elapsed)" -ForegroundColor DarkGray
        }
    }

    if ($pending.Count -gt 0) {
        throw "Provider registration timed out after ${TimeoutSeconds}s. Still pending: $($pending -join ', '). Re-run after Azure finishes (can take 10-30 min for first-time enrollment of some RPs)."
    }
}

# -------- Sanity checks -----------------------------------------------
Write-Step 'Checking az + bicep CLI availability'
az --version | Out-Null
az bicep version | Out-Null

$sub = az account show --query 'id' -o tsv
$tenant = az account show --query 'tenantId' -o tsv
Write-Host "Subscription: $sub" -ForegroundColor Gray
Write-Host "Tenant:       $tenant" -ForegroundColor Gray

$deploymentName = "klz-foundry-$Mode-$(Get-Date -Format 'yyyyMMddHHmm')"

# Resource providers required by main.bicep. Tenant-restricted RPs that the
# az provider show call can't see are skipped silently (logged as DarkYellow).
# Keep this list in sync with new modules added to main.bicep.
$requiredProviders = @(
    'Microsoft.Resources',
    'Microsoft.Authorization',
    'Microsoft.ManagedIdentity',
    'Microsoft.Network',
    'Microsoft.Storage',
    'Microsoft.KeyVault',
    'Microsoft.OperationalInsights',     # LAW
    'Microsoft.Insights',                # App Insights, DCRs, DCEs, workbooks, alerts, diag settings
    'Microsoft.AlertsManagement',        # Smart detection / scheduled query rules
    'Microsoft.CognitiveServices',       # Foundry / Azure OpenAI
    'Microsoft.Search',                  # AI Search
    'Microsoft.ApiManagement',           # APIM (full mode only, harmless in smoke)
    'Microsoft.PolicyInsights',          # Future: Phase B governance baseline
    'Microsoft.Security'                 # Future: Defender for AI in Phase B
)

if ($Mode -in 'smoke', 'full', 'whatif') {
    Ensure-Providers -Required $requiredProviders

    Write-Step 'Linting workbook JSON files'
    & "$PSScriptRoot/Validate-Workbook.ps1" -Path 'observability/workbooks/' -Recurse
    if ($LASTEXITCODE -ne 0) {
        throw "Workbook lint failed. Fix the issues above (e.g. dynamic property accessors using reserved KQL keywords) before deploying."
    }
}

switch ($Mode) {
    'whatif' {
        Write-Step "What-if preview ($deploymentName)"
        az deployment sub what-if `
            --name $deploymentName `
            --location $Location `
            --template-file 'infra/bicep/main.bicep' `
            --parameters $ParameterFile
    }

    { $_ -in 'smoke', 'full' } {
        Write-Step "Deploying ($deploymentName, mode=$Mode)"
        az deployment sub create `
            --name $deploymentName `
            --location $Location `
            --template-file 'infra/bicep/main.bicep' `
            --parameters $ParameterFile

        Write-Step 'Capturing outputs'
        $outputs = az deployment sub show --name $deploymentName --query 'properties.outputs' -o json | ConvertFrom-Json
        $outputs | ConvertTo-Json -Depth 6 | Set-Content -Path "out-$Mode-$Environment.json"
        Write-Host "Saved outputs → out-$Mode-$Environment.json" -ForegroundColor Green
    }

    'teardown' {
        Write-Step 'Teardown — phase 1: pre-delete Foundry agent capability host + CAE to release legionservicelink SAL'
        # Why: the AI Foundry agent service creates a Microsoft.App/managedEnvironments under the foundry account
        # that installs a `legionservicelink` Service Association Link on the AIFoundrySubnet. If we just
        # `az group delete` the platform RG, the SAL pins the VNet for 30-60+ minutes after the CAE goes away —
        # subnet returns InUseSubnetCannotBeDeleted, RG stays in 'Deleting' state for hours. The fix: explicitly
        # delete the agent capability host and the CAE FIRST, then purge Foundry, THEN delete the RGs.
        $platformRg = "rg-$Workload-platform-$Environment"
        $foundryRg = "rg-$Workload-foundry-$Environment"
        $hubRg = "rg-$Workload-hub-$Environment"

        # 1a. Delete agent capability host on each Foundry account (releases the CAE→subnet binding)
        if ((az group exists --name $foundryRg) -eq 'true') {
            $foundryAccounts = az cognitiveservices account list -g $foundryRg -o tsv --query "[].name" 2>$null
            foreach ($acct in $foundryAccounts) {
                Write-Host "  releasing agent capability host on $acct ..." -ForegroundColor DarkGray
                $hostPath = "/subscriptions/$sub/resourceGroups/$foundryRg/providers/Microsoft.CognitiveServices/accounts/$acct/capabilityHosts/default"
                az rest --method DELETE --uri ("https://management.azure.com" + $hostPath + "?api-version=2025-04-01-preview") 2>&1 | Out-Null
                Start-Sleep -Seconds 5
            }
        }

        # 1b. Delete CAEs in the platform RG (releases the subnet SAL)
        if ((az group exists --name $platformRg) -eq 'true') {
            $caes = az resource list -g $platformRg --resource-type "Microsoft.App/managedEnvironments" -o tsv --query "[].name" 2>$null
            foreach ($cae in $caes) {
                Write-Host "  deleting Container Apps Environment $cae ..." -ForegroundColor Yellow
                az containerapp env delete -g $platformRg -n $cae --yes --no-wait 2>&1 | Out-Null
            }
        }

        Write-Step 'Teardown — phase 2: delete Foundry RG first (so account soft-deletes), then platform + hub RGs'
        # Foundry RG goes first because its account is what owns the SAL on the spoke. After the account is
        # soft-deleted, we purge it, and only THEN do we tear down the platform RG so the SAL has cleared.
        if ((az group exists --name $foundryRg) -eq 'true') {
            Write-Host "Deleting $foundryRg (synchronous so we can purge as soon as it's gone) ..." -ForegroundColor Yellow
            az group delete --name $foundryRg --yes 2>&1 | Out-Null
        }

        # Purge soft-deleted Foundry NOW (before touching platform RG) so the SAL starts releasing in parallel
        # with the rest of teardown. Purge is what fully detaches the agent capability host's SAL.
        $deleted = az cognitiveservices account list-deleted --query "[?starts_with(name,'aif-$Workload-$Environment')].{name:name, loc:location}" -o json 2>$null | ConvertFrom-Json
        if ($deleted) {
            foreach ($d in $deleted) {
                Write-Host "Purging soft-deleted Foundry: $($d.name) ..." -ForegroundColor Yellow
                $attempt = 0
                while ($attempt -lt 6) {
                    az cognitiveservices account purge --location $d.loc --resource-group $foundryRg --name $d.name 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { Write-Host "  purged" -ForegroundColor Green; break }
                    $attempt++
                    Start-Sleep -Seconds 30
                }
            }
        }

        # Now delete the rest of the RGs in parallel — the SAL release is in flight.
        foreach ($g in @($platformRg, $hubRg)) {
            if ((az group exists --name $g) -eq 'true') {
                Write-Host "Deleting $g (no-wait) ..." -ForegroundColor Yellow
                az group delete --name $g --yes --no-wait 2>&1 | Out-Null
            }
        }

        Write-Step 'Teardown — phase 3: poll for completion (SAL release can take up to 30 min for agent-enabled deploys)'
        $waited = 0
        $maxWait = 2400  # 40 min — SAL release is the long pole when agent injection was enabled
        while ($waited -lt $maxWait) {
            $stillThere = @()
            foreach ($g in @($platformRg, $hubRg)) {
                if ((az group exists --name $g) -eq 'true') { $stillThere += $g }
            }
            if ($stillThere.Count -eq 0) {
                Write-Host "✅ All RGs deleted after ${waited}s" -ForegroundColor Green
                break
            }
            if ($waited % 60 -eq 0) {
                Write-Host "  [${waited}s] still draining: $($stillThere -join ', ')" -ForegroundColor DarkGray
            }
            Start-Sleep -Seconds 30
            $waited += 30
        }
        if ($waited -ge $maxWait) {
            Write-Host "Timeout at ${maxWait}s — likely orphan SAL pending Microsoft.App RP cleanup pass." -ForegroundColor Yellow
            Write-Host "Residual VNet + NSGs cost \$0/day; will auto-clean within 1-2 hours." -ForegroundColor Yellow
        }

        Write-Host 'Teardown complete. KV soft-deleted vaults auto-purge after 7d.' -ForegroundColor Green
    }
}
