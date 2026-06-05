<#
.SYNOPSIS
    Static lint for Azure Monitor Workbook JSON files.

.DESCRIPTION
    Azure deploys workbooks as opaque JSON. Mistakes in the embedded KQL
    only surface when a human opens the workbook in the portal. This script
    scans every KqlItem in a workbook and runs a battery of static checks:

      1. Reserved KQL operator used as a dotted property accessor on a
         dynamic column. Example:
             BAD :  BackendResponseBody.project
             GOOD:  BackendResponseBody['project']
         The first form is silently accepted by JSON deploy but fails to
         parse at query time with messages like
             "Query could not be parsed at 'project' on line [n,m]"

      2. Unbalanced parentheses / brackets / braces.

      3. (-Live) Optional execution of each query against a real Log
         Analytics workspace to catch references to non-existent tables
         or columns. Requires az CLI and Reader on the workspace.

.PARAMETER Path
    Path to a single workbook .json file OR a directory of workbooks.

.PARAMETER Recurse
    Recurse into subdirectories when Path is a directory.

.PARAMETER Live
    Execute each query against a Log Analytics workspace.

.PARAMETER WorkspaceId
    Log Analytics workspace GUID. Required with -Live.

.EXAMPLE
    ./scripts/Validate-Workbook.ps1 -Path observability/workbooks/finops-showback.json

.EXAMPLE
    ./scripts/Validate-Workbook.ps1 -Path observability/workbooks/ -Recurse

.EXAMPLE
    ./scripts/Validate-Workbook.ps1 `
        -Path observability/workbooks/ -Recurse `
        -Live -WorkspaceId 1c4b8e2a-...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [switch]$Recurse,

    [switch]$Live,

    [string]$WorkspaceId
)

$ErrorActionPreference = 'Stop'

# KQL tabular / pipe operators. When any of these appears as a dotted
# property accessor on a dynamic value the parser treats it as the start
# of a new operator and fails. Bracket notation sidesteps this.
$ReservedKqlOperators = @(
    'project', 'extend', 'where', 'summarize', 'join', 'take', 'top',
    'sort', 'order', 'distinct', 'count', 'union', 'range', 'print',
    'evaluate', 'parse', 'serialize', 'lookup', 'consume', 'getschema',
    'materialize', 'sample', 'find', 'search', 'render', 'invoke',
    'as', 'partition', 'reduce', 'fork', 'facet'
)
$reservedPattern = '\.\s*(' + ($ReservedKqlOperators -join '|') + ')\b'

# Application Insights table-name dialects. A workbook must be scoped
# consistently with the table style it uses, otherwise queries fail with
# "Failed to resolve table or column expression named '<Table>'".
#
#   Workspace-based names (App* prefix) → require sourceId = LAW
#   Classic AI names                     → require sourceId = App Insights component
$WorkspaceAiTables = @(
    'AppDependencies', 'AppExceptions', 'AppRequests', 'AppTraces',
    'AppEvents', 'AppMetrics', 'AppPageViews', 'AppPerformanceCounters',
    'AppBrowserTimings', 'AppAvailabilityResults', 'AppSystemEvents'
)
$ClassicAiTables = @(
    'requests', 'dependencies', 'exceptions', 'traces', 'customEvents',
    'customMetrics', 'pageViews', 'performanceCounters', 'browserTimings',
    'availabilityResults', 'systemEvents'
)
$workspaceAiPattern = '\b(' + ($WorkspaceAiTables -join '|') + ')\b'
$classicAiPattern   = '(?-i)(^|\||\s)(' + ($ClassicAiTables -join '|') + ')\b'

function Get-LineNumber {
    param([string]$Text, [int]$Index)
    return (($Text.Substring(0, $Index) -split "`n").Length)
}

function Test-WorkbookFile {
    param([string]$FilePath)

    Write-Host ""
    Write-Host "=== $FilePath ===" -ForegroundColor Cyan

    try {
        $wb = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "  FAIL parse: $_" -ForegroundColor Red
        return 1
    }

    if (-not $wb.items) {
        Write-Host "  no items found" -ForegroundColor Yellow
        return 0
    }

    $issues   = 0
    $kqlCount = 0
    $idx      = -1
    $usesWorkspaceAi = $false
    $usesClassicAi   = $false

    foreach ($item in $wb.items) {
        $idx++
        if ($item.type -ne 3) { continue }               # KqlItem only
        if (-not $item.content.query) { continue }

        $kqlCount++
        $title = if ($item.content.title) { $item.content.title } else { '(untitled)' }
        $query = [string]$item.content.query

        # Strip string literals before scanning so identifiers that
        # legitimately appear inside quoted strings (e.g. dictionary keys
        # like Properties['gen_ai.project']) don't produce false positives.
        # Length is preserved so reported line numbers stay accurate.
        $scrubbed = [regex]::Replace($query, "'[^'\r\n]*'", {
            param($m) ' ' * $m.Length
        })
        $scrubbed = [regex]::Replace($scrubbed, '"[^"\r\n]*"', {
            param($m) ' ' * $m.Length
        })

        $tileIssues = @()

        # Check 1: reserved-keyword dotted accessor
        $matches = [regex]::Matches($scrubbed, $reservedPattern)
        foreach ($m in $matches) {
            $kw   = $m.Groups[1].Value
            $line = Get-LineNumber -Text $query -Index $m.Index
            $tileIssues += "line $line  reserved KQL operator '.$kw' used as property accessor -- use ['$kw'] instead"
        }

        # Check 2: balanced delimiters (scrubbed too, so brackets inside
        # strings don't get counted)
        $pairs = @{ '(' = ')'; '[' = ']'; '{' = '}' }
        foreach ($open in $pairs.Keys) {
            $close  = $pairs[$open]
            $nOpen  = ([regex]::Matches($scrubbed, [regex]::Escape($open))).Count
            $nClose = ([regex]::Matches($scrubbed, [regex]::Escape($close))).Count
            if ($nOpen -ne $nClose) {
                $tileIssues += "unbalanced delimiters: $nOpen '$open' vs $nClose '$close'"
            }
        }

        # Track App Insights dialect usage so we can flag scope mismatch
        # and mixed-dialect queries at the file level.
        if ([regex]::IsMatch($scrubbed, $workspaceAiPattern)) {
            $usesWorkspaceAi = $true
        }
        if ([regex]::IsMatch($scrubbed, $classicAiPattern, 'None')) {
            $usesClassicAi = $true
        }

        # Check 3: live execution
        if ($Live) {
            if (-not $WorkspaceId) {
                throw "-Live requires -WorkspaceId"
            }
            $tmp = New-TemporaryFile
            try {
                Set-Content -Path $tmp -Value $query -NoNewline
                $null = az monitor log-analytics query `
                    --workspace $WorkspaceId `
                    --analytics-query "@$tmp" `
                    -o none 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $tileIssues += "live query failed (exit $LASTEXITCODE)"
                }
            } finally {
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
        }

        if ($tileIssues.Count -gt 0) {
            $issues += $tileIssues.Count
            Write-Host "  [tile $idx] $title" -ForegroundColor Yellow
            foreach ($issue in $tileIssues) {
                Write-Host "    $issue" -ForegroundColor Red
            }
        }
    }

    # Per-file checks (aggregated across all tiles)
    if ($usesWorkspaceAi -and $usesClassicAi) {
        $issues++
        Write-Host "  [file] mixes workspace-based (App*) and classic App Insights table names" -ForegroundColor Yellow
        Write-Host "    a single workbook cannot resolve both styles -- pick one and align sourceId" -ForegroundColor Red
    }
    elseif ($usesWorkspaceAi) {
        Write-Host "  [hint] uses workspace-based App Insights tables (App*) -- requires sourceId = LAW resource id" -ForegroundColor DarkCyan
    }
    elseif ($usesClassicAi) {
        Write-Host "  [hint] uses classic App Insights tables -- requires sourceId = App Insights component resource id" -ForegroundColor DarkCyan
    }

    if ($issues -eq 0) {
        Write-Host "  OK: $kqlCount KQL tile(s) clean" -ForegroundColor Green
    }
    return $issues
}

# Resolve targets
if (Test-Path -LiteralPath $Path -PathType Container) {
    $files = Get-ChildItem -Path $Path -Filter '*.json' -Recurse:$Recurse -File
} elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
    $files = @(Get-Item -LiteralPath $Path)
} else {
    Write-Host "Path not found: $Path" -ForegroundColor Red
    exit 2
}

if ($files.Count -eq 0) {
    Write-Host "No .json files found under $Path" -ForegroundColor Yellow
    exit 0
}

$total = 0
foreach ($f in $files) {
    $total += Test-WorkbookFile -FilePath $f.FullName
}

Write-Host ""
if ($total -eq 0) {
    Write-Host "PASS: $($files.Count) workbook file(s) clean." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAIL: $total issue(s) across $($files.Count) workbook file(s)." -ForegroundColor Red
    exit 1
}
