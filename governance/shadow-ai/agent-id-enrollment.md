# Enrolling KLZ agent runtimes in Microsoft Entra Agent ID

The KLZ runtime SDK (`governance/agent-runtime/runtime/klz_client.py`) ships
with `KlzClient.from_env`, which uses `DefaultAzureCredential` against an
Entra service principal or user-assigned MI. For shadow-AI containment we
upgrade that to **Microsoft Entra Agent Identity** (Agent ID) per agent
instance, so:

* The Foundry API key is never inside the container.
* `audit.AgentId` matches what's enforced at APIM + Foundry.
* Conditional Access rules in `ca-policies/` can target individual agents.

## Prerequisites

* Entra ID P2 (Agent ID GA license).
* Global Admin or Cloud Application Admin for the bootstrap.
* The Entra MCP / Graph SDK installed (`pip install msgraph-sdk`).
* A registered Agent **Blueprint** that describes what the agent class is allowed to do.

## 1. Create the Blueprint (one per agent class)

```pwsh
# Replace KLZ-Refunds-Agent with your agent name; one Blueprint per class.
$body = @{
  displayName  = "KLZ-Refunds-Agent"
  description  = "Refund processing agent — read-only on customer DB, write on refund queue."
  signInAudience = "AzureADMyOrg"
  capabilities = @{
    requiredResourceAccess = @(
      @{
        resourceAppId  = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
        resourceAccess = @(
          @{ id = "5b567255-7703-4780-807c-7be8301ae99b"; type = "Role" }   # Group.Read.All
        )
      }
    )
  }
}
$payload = $body | ConvertTo-Json -Depth 30
# Use Graph SDK or REST POST to /v1.0/applications + agentic extension when available in GA.
```

The exact API surface for Agent Identity Blueprints is in `agent-governance-toolkit`
upstream — pin the version that matches your tenant rollout ring.

## 2. Create per-instance Agent Identity

Each container / each tenant assignment creates one Agent Identity from
the Blueprint. The KLZ runtime ships an environment contract:

| Env var | Value | Set by |
|---|---|---|
| `KLZ_AGENT_ID` | Object ID of the Agent Identity | Bootstrap script |
| `KLZ_AGENT_BLUEPRINT_ID` | Blueprint object ID | Bootstrap script |
| `KLZ_AGENT_NAME` | Display name (e.g. `KLZ-Refunds-Agent`) | Bootstrap script |
| `KLZ_AGENT_VERSION` | Semver | CI |
| `AZURE_CLIENT_ID` | The Agent Identity's clientId | Bootstrap script |

When `from_env` constructs `KlzConfig`, it now also stamps these into
the audit row via `agent_name` / `agent_version`, so every LAW row in
`KlzAgentAudit_CL` is traceable to one Agent Identity.

## 3. Federate without secrets (preferred)

For each instance, configure Workload Identity Federation back to the
container's compute identity (the Container Apps system MI from
`otel-collector.bicep` or the AKS workload identity for prod):

```pwsh
az ad app federated-credential create `
  --id <agent-identity-clientId> `
  --parameters @{
    name      = "klz-runtime-prod"
    issuer    = "<oidc-issuer-from-container-apps-or-aks>"
    subject   = "system:serviceaccount:klz-runtime:default"
    audiences = @("api://AzureADTokenExchange")
  }
```

The runtime now exchanges its compute identity for an Agent Identity
token at call time — **no secret material ever leaves Azure**.

## 4. Wire CA policies

After Agent Identities exist, fill the `_REPLACE_WITH_KLZ_RUNTIME_SP_ID_`
placeholders in:

* `ca-policies/ca-require-mfa-for-agents.json`
* `ca-policies/ca-block-personal-token.json`

…with the Agent Identity's servicePrincipal object ID. Keep these CA
policies in `enabledForReportingButNotEnforced` for at least one full
sprint before promoting.

## 5. Confirm in audit logs

After deploy, every `KlzAgentAudit_CL` row should now have:

* `AgentName` matching the Blueprint display name
* `CorrelationId` matching the JWT `oid` claim
* APIM access logs (`AzureDiagnostics`) showing the same `oid`

KQL spot-check:

```kql
KlzAgentAudit_CL
| where TimeGenerated > ago(1h)
| join kind=leftouter (AzureDiagnostics | where ResourceType == "SERVICE" and OperationName == "Microsoft.ApiManagement/service/gatewayLogs")
    on $left.CorrelationId == $right.CorrelationId
| project TimeGenerated, AgentName, Decision, OperationId, ResultType
```
