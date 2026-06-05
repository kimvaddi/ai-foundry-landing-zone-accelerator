$ErrorActionPreference = 'Stop'
$sub  = '22222222-2222-2222-2222-222222222222'
$rg   = 'rg-klzfin-platform-dev'
$apim = 'apim-klzfin-dev-c6ej'
$law  = 'log-klzfin-dev-c6ej'
$appi = 'appi-klzfin-dev-c6ej'
$apimId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim"
$lawId  = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$law"
$token  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv

# ---------------------------------------------------------------------------
# STAGE 1: Enable GatewayLogs + GatewayLlmLogs on APIM diagnostic setting
# ---------------------------------------------------------------------------
Write-Host '=== STAGE 1: Enable APIM log categories ===' -ForegroundColor Cyan
$diagBody = @{
    properties = @{
        workspaceId = $lawId
        logs = @(
            @{ category = 'GatewayLogs';    enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } },
            @{ category = 'GatewayLlmLogs'; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } }
        )
        metrics = @(
            @{ category = 'AllMetrics'; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } }
        )
    }
} | ConvertTo-Json -Depth 10
$dsUrl = "https://management.azure.com$apimId/providers/Microsoft.Insights/diagnosticSettings/send-to-law?api-version=2021-05-01-preview"
$tmp = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmp, $diagBody, [System.Text.UTF8Encoding]::new($false))
$dsResp = Invoke-RestMethod -Method Put -Uri $dsUrl -Body $diagBody -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token" }
Remove-Item $tmp
$enabled = $dsResp.properties.logs | Where-Object { $_.enabled } | ForEach-Object { $_.category }
Write-Host "  Enabled logs: $($enabled -join ', ')" -ForegroundColor Green

# ---------------------------------------------------------------------------
# STAGE 2: Get APIM subscription key
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== STAGE 2: Fetch APIM master subscription key ===' -ForegroundColor Cyan
$subListUrl = "https://management.azure.com$apimId/subscriptions?api-version=2024-05-01"
$apimSubs = (Invoke-RestMethod -Method Get -Uri $subListUrl -Headers @{ Authorization = "Bearer $token" }).value
$master = $apimSubs | Where-Object { $_.properties.displayName -like '*all-access*' -or $_.name -eq 'master' } | Select-Object -First 1
$secretsUrl = "https://management.azure.com$apimId/subscriptions/$($master.name)/listSecrets?api-version=2024-05-01"
$secrets = Invoke-RestMethod -Method Post -Uri $secretsUrl -Headers @{ Authorization = "Bearer $token" }
$apimKey = $secrets.primaryKey
Write-Host "  Master sub:  $($master.properties.displayName)"
Write-Host "  Key prefix:  $($apimKey.Substring(0,8))..."

# ---------------------------------------------------------------------------
# STAGE 3: Fire LLM traffic through APIM gateway
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== STAGE 3: Fire chat completions through APIM ===' -ForegroundColor Cyan
$gatewayUrl = "https://$apim.azure-api.net/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-08-01-preview"
$projects = @(
    @{ name = 'foundry-controlplane'; sub = 'sub-control-001'; cc = 'CC-1001' },
    @{ name = 'finops-platform';      sub = 'sub-finops-002';  cc = 'CC-2002' },
    @{ name = 'demo-project-c';      sub = 'sub-demo-003';    cc = 'CC-3003' }
)
$prompts = @(
    'Reply with one word: hello',
    'Reply with one word: world',
    'Reply with one word: tokens',
    'Reply with one word: pricing',
    'Reply with one word: showback',
    'Reply with one word: quota'
)
$callIdx = 0
$results = @()
$tokenRecords = @()    # holds usage we'll later push as customMetrics
foreach ($p in $prompts) {
    $proj = $projects[$callIdx % $projects.Count]
    $callIdx++
    $body = @{
        messages   = @(@{ role = 'user'; content = $p })
        max_tokens = 8
        model      = 'gpt-4o-mini'
    } | ConvertTo-Json -Depth 5 -Compress
    $hdr = @{
        'Ocp-Apim-Subscription-Key' = $apimKey
        'x-project-name'            = $proj.name
        'x-project'                 = $proj.name
        'x-use-case'                = 'workbook-smoke-test'
        'x-cost-center'             = $proj.cc
        'x-subscription-id'         = $proj.sub
        'api-key'                   = 'unused-mi-flow'
        'Content-Type'              = 'application/json'
    }
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-RestMethod -Method Post -Uri $gatewayUrl -Headers $hdr -Body $body
        $sw.Stop()
        $reply = $resp.choices[0].message.content
        $usage = $resp.usage
        Write-Host ("  [{0}] project={1,-22}  in={2,3}  out={3,3}  total={4,3}  {5}ms  -> '{6}'" -f $callIdx,$proj.name,$usage.prompt_tokens,$usage.completion_tokens,$usage.total_tokens,$sw.ElapsedMilliseconds,$reply) -ForegroundColor Green
        $results += @{ ok = $true; project = $proj.name }
        $tokenRecords += @{
            project = $proj.name; sub = $proj.sub; cc = $proj.cc
            model = ($resp.model -as [string])
            promptTokens = [int]$usage.prompt_tokens
            completionTokens = [int]$usage.completion_tokens
            totalTokens = [int]$usage.total_tokens
        }
    } catch {
        Write-Host "  [$callIdx] project=$($proj.name)  FAILED  $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $errBody = $_.ErrorDetails.Message
                Write-Host "     body: $errBody" -ForegroundColor DarkRed
            } catch {}
        }
        $results += @{ ok = $false; project = $proj.name; err = $_.Exception.Message }
    }
    Start-Sleep -Milliseconds 500
}
$okCount = ($results | Where-Object { $_.ok }).Count
Write-Host ''
Write-Host "  Success: $okCount / $($results.Count)" -ForegroundColor $(if ($okCount -gt 0) { 'Green' } else { 'Red' })

# ---------------------------------------------------------------------------
# STAGE 3b: Push token customMetrics (so finops workbook has cost-able data)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== STAGE 3b: Push token usage as customMetrics (namespace=AiGateway) ===' -ForegroundColor Cyan
$connStr = az resource show -g $rg -n $appi --resource-type Microsoft.Insights/components --query "properties.ConnectionString" -o tsv
$ikey   = ($connStr -split ';' | Where-Object { $_ -like 'InstrumentationKey=*' }) -replace 'InstrumentationKey=',''
$ingest = (($connStr -split ';' | Where-Object { $_ -like 'IngestionEndpoint=*' }) -replace 'IngestionEndpoint=','').TrimEnd('/')

$metricTelemetry = @()
$now = [DateTime]::UtcNow
foreach ($t in $tokenRecords) {
    foreach ($mn in @(
        @{ name = 'PromptTokens';     value = $t.promptTokens },
        @{ name = 'CompletionTokens'; value = $t.completionTokens },
        @{ name = 'TotalTokens';      value = $t.totalTokens }
    )) {
        $metricTelemetry += @{
            name = 'Microsoft.ApplicationInsights.Metric'
            time = $now.ToString('o')
            iKey = $ikey
            tags = @{
                'ai.cloud.role'         = 'apim-klzfin-dev-c6ej'
                'ai.cloud.roleInstance' = 'apim-emit'
            }
            data = @{
                baseType = 'MetricData'
                baseData = @{
                    ver     = 2
                    metrics = @(@{
                        name  = $mn.name
                        kind  = 'Measurement'
                        value = $mn.value
                        count = 1
                    })
                    properties = @{
                        'MetricNamespace' = 'AiGateway'
                        'ApiName'         = 'foundry-openai'
                        'OperationId'     = 'chat-completions'
                        'ProjectName'     = $t.project
                        'CostCenter'      = $t.cc
                        'SubscriptionId'  = $t.sub
                        'ModelName'       = $t.model
                        'UseCase'         = 'workbook-smoke-test'
                    }
                }
            }
        }
    }
}
$batch = ($metricTelemetry | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join "`n"
try {
    $r = Invoke-RestMethod -Method Post -Uri "$ingest/v2.1/track" -Body $batch -ContentType 'application/json'
    Write-Host "  Metric ingest: accepted=$($r.itemsAccepted)/received=$($r.itemsReceived)  ($($metricTelemetry.Count) data points)" -ForegroundColor Green
} catch {
    Write-Host "  Metric ingest FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "    $($_.ErrorDetails.Message)" -ForegroundColor DarkRed }
}

# ---------------------------------------------------------------------------
# STAGE 4: Send synthetic OTEL AppDependencies into App Insights
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== STAGE 4: Inject synthetic AppDependencies (gen_ai + tool spans) ===' -ForegroundColor Cyan
$connStr = az resource show -g $rg -n $appi --resource-type Microsoft.Insights/components --query "properties.ConnectionString" -o tsv
# Parse instrumentation key + ingestion endpoint
$ikey = ($connStr -split ';' | Where-Object { $_ -like 'InstrumentationKey=*' }) -replace 'InstrumentationKey=',''
$ingest = ($connStr -split ';' | Where-Object { $_ -like 'IngestionEndpoint=*' }) -replace 'IngestionEndpoint=',''
$ingest = $ingest.TrimEnd('/')
Write-Host "  Ingest:  $ingest"
Write-Host "  IKey:    $($ikey.Substring(0,8))..."

# Build telemetry batch: 3 projects x 4 dependencies each (gen_ai.completion, gen_ai.embedding, tool.fabric, tool.search)
$telemetry = @()
$nowUtc = [DateTime]::UtcNow
foreach ($p in $projects) {
    $deps = @(
        @{ name = 'gen_ai.completion';   duration = (Get-Random -Min 800 -Max 2500);  model = 'gpt-4o-mini' },
        @{ name = 'gen_ai.completion';   duration = (Get-Random -Min 600 -Max 2000);  model = 'gpt-4o-mini' },
        @{ name = 'gen_ai.completion';   duration = (Get-Random -Min 700 -Max 2200);  model = 'gpt-4o-mini' },
        @{ name = 'tool.fabric.query';   duration = (Get-Random -Min 3000 -Max 9000); model = $null },
        @{ name = 'tool.fabric.query';   duration = (Get-Random -Min 2500 -Max 8500); model = $null },
        @{ name = 'tool.search.lookup';  duration = (Get-Random -Min 80  -Max 300);   model = $null },
        @{ name = 'tool.kv.get-secret';  duration = (Get-Random -Min 20  -Max 90);    model = $null }
    )
    foreach ($d in $deps) {
        $tid = [Guid]::NewGuid().ToString('N')
        $sid = [Guid]::NewGuid().ToString('N').Substring(0,16)
        $props = @{
            'gen_ai.project'      = $p.name
            'gen_ai.system'       = 'azure-openai'
            'span.kind'           = if ($d.name -like 'tool.*') { 'tool' } else { 'agent' }
            'cost.center'         = $p.cc
            'azure.subscription'  = $p.sub
        }
        if ($d.model) {
            $props['gen_ai.request.model']  = $d.model
            $props['gen_ai.response.model'] = $d.model
        }
        $tel = @{
            name = 'Microsoft.ApplicationInsights.RemoteDependency'
            time = $nowUtc.AddSeconds(- (Get-Random -Min 60 -Max 1800)).ToString('o')
            iKey = $ikey
            tags = @{
                'ai.cloud.role'         = 'foundry-agent-smoke'
                'ai.cloud.roleInstance' = 'smoke-instance-1'
                'ai.operation.id'       = $tid
                'ai.operation.parentId' = $sid
            }
            data = @{
                baseType = 'RemoteDependencyData'
                baseData = @{
                    ver        = 2
                    name       = $d.name
                    id         = $sid
                    resultCode = '200'
                    duration   = ('00:00:{0:00}.{1:000}' -f ([math]::Floor($d.duration/1000)), ($d.duration % 1000))
                    success    = $true
                    type       = if ($d.name -like 'tool.*') { 'InProc' } else { 'HTTP' }
                    target     = if ($d.name -like 'gen_ai.*') { 'aif-klzfin-dev-c6ej.cognitiveservices.azure.com' } else { 'internal' }
                    data       = $d.name
                    properties = $props
                }
            }
        }
        $telemetry += $tel
    }
}

$batchJson = ($telemetry | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress }) -join "`n"
$ingestUrl = "$ingest/v2.1/track"
try {
    $r = Invoke-RestMethod -Method Post -Uri $ingestUrl -Body $batchJson -ContentType 'application/json'
    Write-Host "  Ingest response: accepted=$($r.itemsAccepted)/received=$($r.itemsReceived)" -ForegroundColor Green
} catch {
    Write-Host "  Ingest FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "    $($_.ErrorDetails.Message)" -ForegroundColor DarkRed }
}

# ---------------------------------------------------------------------------
# STAGE 5: Tell the user what to do next
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== STAGE 5: Wait for ingestion ===' -ForegroundColor Cyan
Write-Host '  AppInsights dependency telemetry typically appears in 1-3 min.'
Write-Host '  APIM GatewayLlmLogs typically appear in 2-5 min.'
Write-Host ''
Write-Host '  Re-run scripts/verify-traffic.ps1 in ~5 min to confirm data is queryable.' -ForegroundColor Yellow
