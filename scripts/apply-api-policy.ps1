$ErrorActionPreference = 'Stop'
$sub  = '22222222-2222-2222-2222-222222222222'
$apim = 'apim-klzfin-dev-c6ej'
$apimId = "/subscriptions/$sub/resourceGroups/rg-klzfin-platform-dev/providers/Microsoft.ApiManagement/service/$apim"
$tok  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv

# Dynamic API policy: forward to Foundry preserving original path & body
$apiPolicy = @'
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="cs-token" />
    <set-variable name="aoai-url" value="@("https://aif-klzfin-dev-c6ej.cognitiveservices.azure.com" + context.Request.OriginalUrl.Path + context.Request.OriginalUrl.QueryString)" />
    <send-request mode="new" response-variable-name="aoai-resp" timeout="120" ignore-error="false">
      <set-url>@((string)context.Variables["aoai-url"])</set-url>
      <set-method>@(context.Request.Method)</set-method>
      <set-header name="Authorization" exists-action="override">
        <value>@("Bearer " + (string)context.Variables["cs-token"])</value>
      </set-header>
      <set-header name="Content-Type" exists-action="override">
        <value>application/json</value>
      </set-header>
      <set-body>@((string)context.Request.Body.As<string>(preserveContent: true))</set-body>
    </send-request>
    <return-response response-variable-name="aoai-resp" />
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'@
Write-Host '=== Apply final dynamic API policy ==='
$body = @{ properties = @{ value = $apiPolicy; format = 'rawxml' } } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Put -Uri "https://management.azure.com$apimId/apis/foundry-openai/policies/policy?api-version=2024-05-01" -Headers @{Authorization="Bearer $tok"; 'Content-Type'='application/json'} -Body $body | Out-Null
Write-Host '  PUT OK' -ForegroundColor Green

# Save the working policy to repo
$apiPolicy | Out-File -Encoding UTF8 -NoNewline "$PSScriptRoot\..\apim-policies\api-foundry-openai-policy.xml"
Write-Host '  Saved policy to apim-policies/api-foundry-openai-policy.xml' -ForegroundColor Gray
