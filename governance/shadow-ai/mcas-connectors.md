# MCAS / Defender for Cloud Apps (DCA) connector onboarding

How to wire DCA so it surfaces unsanctioned AI usage across the tenant.
**Manual procedure — operator-driven. Nothing in this folder auto-creates connectors.**

## Required roles

* Microsoft Entra: **Global Reader** (for app discovery), **Security Administrator** (for connector creation).
* Azure: **Reader** on the subscription holding the LAW + APIM.
* DCA portal access at https://security.microsoft.com (Defender XDR portal, "Cloud apps" blade).

## 1. Cloud Discovery — surface unsanctioned AI

1. Defender XDR → Cloud apps → Cloud Discovery → Snapshot reports / Continuous reports.
2. Create a **Continuous report** named `KLZ — AI shadow IT`.
3. Data source: choose log collector or native connector matching your egress stack:
   * **Azure Firewall** — use the [native connector](https://learn.microsoft.com/defender-cloud-apps/azure-firewall-integration).
   * **Zscaler / Netskope / Palo Alto** — pre-built parser.
   * **Generic** — upload CEF / W3C every 24h.
4. Filter the report by **Category = Generative AI**.
5. Set alerting: e.g. "alert when ≥ 10 unique users hit a non-sanctioned GenAI app in 24h".

## 2. Tag sanctioned vs unsanctioned

For each AI app the discovery report surfaces:

| App | Action |
|---|---|
| chat.openai.com (consumer) | Mark **Unsanctioned** + add to firewall block list (see `firewall-fqdn-allowlist.txt`). |
| platform.openai.com | Decision: usually unsanctioned (commercial data) → tag accordingly. |
| copilot.microsoft.com (M365) | **Sanctioned** if covered by your M365 Copilot contract; else monitor. |
| ai.azure.com (Foundry) | **Sanctioned** — KLZ tenant. |
| claude.ai | **Unsanctioned** unless under contract. |
| gemini.google.com | **Unsanctioned**. |
| github.com/copilot | **Sanctioned** if enterprise plan. |

## 3. API connectors

Onboard a connector for each sanctioned cloud the company uses, so DCA
can read activity logs:

* **Microsoft Azure** — [Azure connector](https://learn.microsoft.com/defender-cloud-apps/connect-azure). Required for Foundry + APIM signal.
* **Microsoft 365** — already present in DCA by default for Defender XDR-licensed tenants.
* **GitHub** — for Copilot Business / Enterprise audit log.
* **Google Workspace** if applicable.
* **AWS** if applicable.

Each connector requires its own admin consent flow — read the linked doc.

## 4. Wire DCA alerts to the same notification stub

DCA alerts can post to webhooks via Power Automate:

1. DCA portal → Settings → Microsoft Defender XDR → Alert tuning → "Send alerts to webhook" (Power Automate connector).
2. In Power Automate, create a flow:
   * Trigger: "When a Defender for Cloud Apps alert is created".
   * Action: HTTP → POST to the URL output by `infra/bicep/modules/observability/notifications.bicep` (`logicAppCallbackUrl`).

This way DCA findings fan out to the same Teams / ServiceNow / email
endpoints as Azure Monitor alerts — single inbox for security ops.

## What to do next

Re-run Cloud Discovery monthly. Promote DCA findings into a Defender
incident if a user hits ≥3 unsanctioned GenAI apps in 7 days.
