# KLZ Shadow-AI Controls (Phase C)

Tenant-wide controls that surface and contain **unsanctioned AI use** —
employees pasting customer data into chat.openai.com, agents using stolen
or unmanaged identities, browser plugins that exfiltrate documents, etc.

## ⚠️ Safety contract

Every artifact in this folder follows the KLZ Phase C safety contract:

| Control | Default state | Why |
|---|---|---|
| Conditional Access policies | `state: 'enabledForReportingButNotEnforced'` | Report-only first — never block a user without sign-off. |
| MCAS / Defender for Cloud Apps connectors | Reference docs only — no auto-onboard | Connector creation requires Global Reader + DCA admin, audited. |
| Purview DLP policies | `mode: 'TestWithoutNotifications'` (simulation) | Same as above — surface findings, do not block users yet. |
| Firewall FQDN allowlist | Plain text reference list, NOT applied | Operator copies into Azure Firewall / SWG with change ticket. |
| Agent ID enrollment | Markdown procedure only | Requires Entra Agent Identity sign-off. |

**Nothing in here ships at deploy-time. Operators apply these artifacts
manually via documented change tickets after CISO / cybersec sign-off.**

## Owner contacts (D4 placeholders)

Every artifact in this folder uses **placeholder tokens** for app GUIDs,
group IDs, and owner emails. The canonical map lives in
[../../placeholders/stakeholders.template.md](../../placeholders/stakeholders.template.md).

| Folder | Token replacement owner | Sign-off required |
|---|---|---|
| `ca-policies/` | **IAM Owner** (default placeholder: `iam-team@contoso.example`) | CISO + Identity team before flipping CA state from `enabledForReportingButNotEnforced` to `enabled`. |
| `mcas-connectors.md` | **SecOps Owner** (default placeholder: `secops@contoso.example`) | SecOps lead before connector creation. |
| `purview-dlp/` | **Compliance Owner** (default placeholder: `compliance@contoso.example`) | Compliance + CISO before flipping DLP mode from `TestWithoutNotifications` to `Enable`. |

Run the token-swap script in `stakeholders.template.md` against a working copy
of the repo before importing any of these into Graph / Purview.

## Folder map

```
governance/shadow-ai/
├── README.md                          (this file)
├── ca-policies/
│   ├── ca-block-unmanaged-ai.json     Entra CA, report-only
│   ├── ca-require-mfa-for-agents.json Entra CA, report-only
│   └── ca-block-personal-token.json   Entra CA, report-only
├── mcas-connectors.md                 How to onboard Azure / GenAI apps
├── purview-dlp/
│   ├── dlp-pii-to-genai.json          Purview DLP, simulation mode
│   └── dlp-source-to-genai.json       Purview DLP, simulation mode
├── agent-id-enrollment.md             How to enroll runtime in Entra Agent ID
└── firewall-fqdn-allowlist.txt        Curated list of approved AI FQDNs
```

## Order of rollout (recommended)

1. **Discover** — Turn on Defender for Cloud Apps "Cloud Discovery" using
   the firewall log connector. No blocking; just surface what users
   already do.
2. **Catalog** — Mark sanctioned vs unsanctioned apps in the DCA portal.
3. **Report** — Enable the CA + DLP policies in this folder in
   report-only mode for 2–4 weeks.
4. **Notify** — Switch DLP to "TestWithNotifications" — users see a
   popup explaining the policy, but action is not blocked.
5. **Enforce** — After CISO sign-off, switch CA to enforced and DLP to
   "Enabled". This is the only step that requires an explicit change
   ticket; the rest are observability-only.

## Cross-references

- `policy/definitions/defender-for-ai-dine.json` — surfaces Defender for AI Workloads coverage at sub scope.
- `policy/definitions/cognitive-private-only.json` — denies new Cognitive Services accounts with public network access.
- `governance/agent-runtime/policies/*.yaml` — the runtime policies a sanctioned agent must enforce. Shadow agents won't have these — that's the whole point of the controls in this folder.
