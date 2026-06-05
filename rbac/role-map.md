# RBAC role map — Foundry Enterprise Landing Zone

> Goal: least privilege via PIM on every persona. Service principals get standing access; humans get eligible assignments only.

## Personas → roles (DEV)

| Persona | Scope | Role | Why |
|---|---|---|---|
| **Platform Engineering** | Management Group | `Contributor` | Manage the landing zone modules + policy assignments |
| **Platform Engineering** | Management Group | `Resource Policy Contributor` | Author / modify initiative |
| **Project Owner** (e.g. Knowledge Search Books team lead) | Foundry project | `Azure AI Project Manager` | Create/update agents within their project only |
| **AI Developer** | Foundry project | `Azure AI User` | Build + invoke agents, no model deploy |
| **App service principal** (agent runtime MI) | Foundry project | `Cognitive Services User` | Call inference endpoints |
| **App service principal** | AI Search | `Search Index Data Reader` + `Search Service Contributor` | Vector search reads + index updates |
| **APIM managed identity** | Foundry account | `Cognitive Services OpenAI User` | Forward chat / embedding calls |
| **FinOps reviewer** | Subscription | `Cost Management Reader` + `Reader` | Read showback dashboards |
| **SecOps** | Subscription | `Security Reader` + workspace `Log Analytics Reader` | Read Defender alerts + KQL audit logs |
| **Pipeline service principal** (`02-provision-project.yml`) | RG-DEV-AI | `Contributor` (scoped to RG only) | Create new Foundry projects under the account |
| **Pipeline service principal** | Foundry account | `Azure AI Account Owner` | Project management API |

## PIM model

- All human roles assigned **Eligible** in PIM, not Active.
- Maximum activation duration: 8 hours for Project Owner, 1 hour for Cog Services data plane roles.
- Activation requires MFA + business justification.
- Approval required for Contributor at sub scope.

## What MUST NOT be granted (anti-pattern detection)

| Anti-pattern | Why it's bad |
|---|---|
| Owner at subscription | Bypasses PIM, lets anyone delete the LZ |
| Reader at MG to large groups | Disclosure risk for embedded secrets in Bicep params history |
| Cognitive Services Contributor to developers | Lets them issue keys → bypass disableLocalAuth intent |
| Key Vault Administrator on shared KV | Should be Key Vault Crypto Officer (key rotation) + Key Vault Secrets User (read) split |

## How this maps to the policy initiative

- `cogsvc-disable-local-auth` enforces the *intent* that even an over-privileged user can't issue keys
- `cogsvc-managed-identity` enforces that runtime identities are MI, not keys
- `kv-require-soft-delete` + `kv-require-purge-protection` mean even if a "Key Vault Administrator" deletes a vault, it recovers
