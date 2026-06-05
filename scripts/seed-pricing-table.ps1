<#
.SYNOPSIS
    Seed PRICING_CL and SUBSCRIPTION_QUOTA_CL with a representative price book.

.DESCRIPTION
    Posts sample rows to a Direct Data Collection Rule via the DCE Logs Ingestion
    API using AAD OAuth so the cost/usage workbooks have data on first open.
    The runner identity needs role 'Monitoring Metrics Publisher' on the target DCR.
    Refresh the embedded price table against current Microsoft public pricing before
    customer use — the values shipped here are illustrative, not authoritative.

.EXAMPLE
    ./scripts/seed-pricing-table.ps1 `
        -DceEndpoint           https://dce-log-klzfin-dev-c6ej-at88.eastus2.ingest.monitor.azure.com `
        -PricingDcrImmutableId dcr-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa `
        -QuotaDcrImmutableId   dcr-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DceEndpoint,                # https://<dce>.<region>.ingest.monitor.azure.com
    [Parameter(Mandatory)] [string] $PricingDcrImmutableId,      # dcr-immutable-id
    [Parameter(Mandatory)] [string] $QuotaDcrImmutableId,        # dcr-immutable-id
    [string] $StreamPricing = 'Custom-PRICING_CL',
    [string] $StreamQuota   = 'Custom-SUBSCRIPTION_QUOTA_CL'
)

$ErrorActionPreference = 'Stop'
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$token = (az account get-access-token --resource 'https://monitor.azure.com' --query 'accessToken' -o tsv)
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

# ---- Sample price book (2026 representative numbers; refresh from MS docs) ----
$pricing = @(
    @{ TimeGenerated = $now; Model = 'gpt-4o';            Region = 'eastus2'; Currency = 'USD'; InputPricePer1KTokens = 0.005;   OutputPricePer1KTokens = 0.015 },
    @{ TimeGenerated = $now; Model = 'gpt-4o-mini';       Region = 'eastus2'; Currency = 'USD'; InputPricePer1KTokens = 0.00015; OutputPricePer1KTokens = 0.0006 },
    @{ TimeGenerated = $now; Model = 'text-embedding-3-large'; Region = 'eastus2'; Currency = 'USD'; InputPricePer1KTokens = 0.00013; OutputPricePer1KTokens = 0 },
    @{ TimeGenerated = $now; Model = 'o3-mini';           Region = 'eastus2'; Currency = 'USD'; InputPricePer1KTokens = 0.0011;  OutputPricePer1KTokens = 0.0044 }
)

# ---- Sample quota rows --------------------------------------------------
$sub = az account show --query 'id' -o tsv
$quota = @(
    @{ TimeGenerated = $now; SubscriptionId = $sub; ProjectName = 'smoke';           CostCenter = 'Platform-Demo'; MonthlyQuotaUsd = 100;  AlertThresholdPct = 80 },
    @{ TimeGenerated = $now; SubscriptionId = $sub; ProjectName = 'knowledge-search'; CostCenter = 'MRO-Ops';        MonthlyQuotaUsd = 1500; AlertThresholdPct = 80 }
)

function Post-Stream([string]$dcrImmutable, [string]$stream, [array]$rows) {
    $body = $rows | ConvertTo-Json -Depth 6 -AsArray
    $uri  = "$DceEndpoint/dataCollectionRules/$dcrImmutable/streams/$stream`?api-version=2023-01-01"
    Write-Host "POST $uri  ($($rows.Count) rows)" -ForegroundColor Cyan
    Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $body | Out-Null
}

Post-Stream -dcrImmutable $PricingDcrImmutableId -stream $StreamPricing -rows $pricing
Post-Stream -dcrImmutable $QuotaDcrImmutableId   -stream $StreamQuota   -rows $quota

Write-Host 'Seed complete. Rows will be visible in LAW after ~2-5 minutes.' -ForegroundColor Green
