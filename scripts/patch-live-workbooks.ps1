$ErrorActionPreference = 'Stop'

# Live-patch both workbook resources to match the JSON files in
# observability/workbooks/ and (re)point sourceId at the LAW.
#
# CRITICAL: az workbook PATCH effectively REPLACES the entire `properties`
# object rather than merging into it, so we MUST send every required
# property (displayName, category, version, serializedData, sourceId) on
# every call. Omitting any of them sets it to null and the portal shows
# "This item could not be restored." Body must also be UTF-8 NO-BOM.

$sub  = '22222222-2222-2222-2222-222222222222'
$rg   = 'rg-klzfin-platform-dev'
$law  = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/log-klzfin-dev-c6ej"
$appi = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/components/appi-klzfin-dev-c6ej"
$api  = '2023-06-01'
$loc  = 'eastus2'

$targets = @(
    @{
        Name        = 'a86ce4f2-ff69-5782-b458-7913f50e4b66'
        File        = 'observability/workbooks/agent-performance.json'
        Label       = 'agent-performance'
        DisplayName = 'Foundry — Agent Performance & Tool Latency'
        SourceId    = $law   # queries AppDependencies / AppRequests (LAW tables)
    },
    @{
        Name        = '6a30e1c1-9151-5ddc-b1bf-53772d92655a'
        File        = 'observability/workbooks/finops-showback.json'
        Label       = 'finops-showback'
        DisplayName = 'Foundry — FinOps Showback'
        SourceId    = $appi  # queries customMetrics (App Insights classic table)
    }
)

# UTF-8 NO-BOM. `az rest --body @file` chokes on BOM-prefixed JSON.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

foreach ($t in $targets) {
    Write-Host ''
    Write-Host "Patching $($t.Label) ($($t.Name))..." -ForegroundColor Cyan

    $serialized = Get-Content -Path $t.File -Raw
    if ([string]::IsNullOrWhiteSpace($serialized)) {
        throw "Source file $($t.File) is empty"
    }

    $body = [ordered]@{
        kind       = 'shared'
        location   = $loc
        tags       = @{ 'hidden-title' = $t.DisplayName }
        properties = [ordered]@{
            displayName    = $t.DisplayName
            category       = 'workbook'
            version        = '1.0'
            sourceId       = $t.SourceId
            serializedData = $serialized
        }
    } | ConvertTo-Json -Depth 50 -Compress

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $body, $utf8NoBom)

        $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Insights/workbooks/$($t.Name)?api-version=$api"
        $resultJson = az rest --method PATCH --url $url --body "@$tmp" -o json
        if ($LASTEXITCODE -ne 0) { throw "PATCH failed for $($t.Label)" }
        $result = $resultJson | ConvertFrom-Json

        Write-Host "  displayName     = $($result.properties.displayName)" -ForegroundColor Green
        Write-Host "  category        = $($result.properties.category)" -ForegroundColor Green
        Write-Host "  version         = $($result.properties.version)" -ForegroundColor Green
        Write-Host "  sourceId        = $($result.properties.sourceId)" -ForegroundColor Green
        Write-Host "  serializedData  = $($result.properties.serializedData.Length) chars" -ForegroundColor Green
        Write-Host "  timeModified    = $($result.properties.timeModified)" -ForegroundColor Green

        # Hard post-condition: anything we sent must round-trip non-null.
        if (-not $result.properties.displayName)    { throw "displayName came back null on $($t.Label)" }
        if (-not $result.properties.serializedData) { throw "serializedData came back null on $($t.Label)" }
        if (-not $result.properties.version)        { throw "version came back null on $($t.Label)" }
        if (-not $result.properties.sourceId)       { throw "sourceId came back null on $($t.Label)" }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Both workbooks repaired.' -ForegroundColor Green
