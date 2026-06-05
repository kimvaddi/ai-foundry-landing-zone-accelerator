# Tier 2 substitution helper v2 — uses System.Text.Json.Nodes to preserve
# array shapes (PowerShell's ConvertTo-Json collapses 1-elem arrays to scalars).
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $MapFile,
    [Parameter(Mandatory)] [string] $OutDir
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName 'System.Text.Json'

$map = Get-Content $MapFile -Raw | ConvertFrom-Json
$tokens = @{
    '_REPLACE_WITH_OPENAI_APP_ID_'                     = ($map.apps | Where-Object Name -eq 'openai').AppId
    '_REPLACE_WITH_ANTHROPIC_APP_ID_'                  = ($map.apps | Where-Object Name -eq 'anthropic').AppId
    '_REPLACE_WITH_GEMINI_APP_ID_'                     = ($map.apps | Where-Object Name -eq 'gemini').AppId
    '_REPLACE_WITH_SANCTIONED_M365_COPILOT_APP_ID_'    = ($map.apps | Where-Object Name -eq 'm365-copilot').AppId
    '_REPLACE_WITH_SANCTIONED_FOUNDRY_PROJECT_APP_ID_' = ($map.apps | Where-Object Name -eq 'foundry-project').AppId
    '_REPLACE_WITH_FOUNDRY_PROJECT_APP_ID_'            = ($map.apps | Where-Object Name -eq 'foundry-project').AppId
    '_REPLACE_WITH_APIM_GATEWAY_APP_ID_'               = ($map.apps | Where-Object Name -eq 'apim').AppId
    '_REPLACE_WITH_AI_RESEARCH_GROUP_OBJECT_ID_'       = $map.aiResearchGroup.ObjectId
    '_REPLACE_WITH_KLZ_RUNTIME_SP_ID_'                 = $map.runtimeApp.SpObjectId
}

function Strip-UnderscoreKeys {
    param([System.Text.Json.Nodes.JsonNode] $Node)
    if ($null -eq $Node) { return }
    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        $obj = [System.Text.Json.Nodes.JsonObject]$Node
        $keysToRemove = @()
        foreach ($prop in $obj.GetEnumerator()) {
            if ($prop.Key.StartsWith('_')) { $keysToRemove += $prop.Key }
        }
        foreach ($k in $keysToRemove) { [void]$obj.Remove($k) }
        foreach ($prop in $obj.GetEnumerator()) { Strip-UnderscoreKeys -Node $prop.Value }
    } elseif ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        foreach ($item in $Node) { Strip-UnderscoreKeys -Node $item }
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$inputs = @(
    'governance/shadow-ai/ca-policies/ca-block-unmanaged-ai.json',
    'governance/shadow-ai/ca-policies/ca-require-mfa-for-agents.json',
    'governance/shadow-ai/ca-policies/ca-block-personal-token.json',
    'governance/shadow-ai/purview-dlp/dlp-pii-to-genai.json',
    'governance/shadow-ai/purview-dlp/dlp-source-to-genai.json'
)
$writeOpts = [System.Text.Json.JsonSerializerOptions]::new()
$writeOpts.WriteIndented = $true

foreach ($f in $inputs) {
    $raw = Get-Content $f -Raw
    foreach ($k in $tokens.Keys) { $raw = $raw.Replace($k, $tokens[$k]) }
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($raw)
    Strip-UnderscoreKeys -Node $node
    $json = $node.ToJsonString($writeOpts)
    $outFile = Join-Path $OutDir ([System.IO.Path]::GetFileName($f))
    [System.IO.File]::WriteAllText($outFile, $json)
    Write-Host "  wrote $outFile"
}
Write-Host ""
Write-Host "Token substitution complete (System.Text.Json.Nodes preserves array shapes)."
