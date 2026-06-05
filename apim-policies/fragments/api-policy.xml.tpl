<!--
  api-policy.xml.tpl — assembled API-level policy template

  Three placeholders get substituted at deploy time by the apim-ai-api module
  (one per Stage B toggle). When the toggle is off, the corresponding fragment
  resolves to an empty string and the placeholder vanishes from the policy.

  Always-on elements:
    - set-backend-service backend-id="foundry-openai"
    - authentication-managed-identity (Foundry MI auth)

  Ordering matters: content-safety FIRST (cheapest to fail-fast),
  then semantic-cache lookup (may short-circuit the backend call),
  then backend routing + MI auth.
-->
<policies>
  <inbound>
    <base />
    __CONTENT_SAFETY_INBOUND__
    __SEMANTIC_CACHE_INBOUND__
    <set-backend-service backend-id="foundry-openai" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
  </inbound>
  <backend><base /></backend>
  <outbound>
    __SEMANTIC_CACHE_OUTBOUND__
    <base />
  </outbound>
  <on-error><base /></on-error>
</policies>
