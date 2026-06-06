# KLZ Accelerator — rollout package

This folder is the package an **operator** runs against the Foundry tenant to
get from "accelerator installed" to "policy + notifications are governing the
AI Landing Zone."

A parallel `test-harness/` runs the same scripts against a **synthetic** MG
hierarchy in a sandbox tenant so changes can be verified before they touch a
production tenant.

```
rollout/
├── README.md                  <- you are here
├── customer-runbook.md             <- the human-readable, copy-paste runbook
├── config/
│   ├── customer.psd1.template <- copy + fill in (.psd1 is gitignored)
│   └── pilot-test.psd1          <- pre-filled config for the test harness
├── scripts/                   <- THE ROLLOUT — what runs in a production tenant
│   ├── 00-preflight.ps1
│   ├── 10-mg-hierarchy-ensure.ps1
│   ├── 15-subscription-move-under-mg.ps1
│   ├── 20-mg-policy-assign.ps1
│   ├── 30-notifications-enable.ps1
│   ├── 40-shadow-ai-ca.ps1    <- stub for the shadow-AI / Conditional Access track
│   └── 99-rollback-all.ps1
└── test-harness/              <- THE SANDBOX — what runs in a dev tenant
    ├── README.md
    ├── step-01-create-test-parent-mg.ps1
    ├── step-02-run-mg-rollout.ps1
    ├── step-03-verify-compliance.ps1
    ├── step-04-test-teams-notification.ps1
    ├── step-05-test-deny-mode.ps1
    ├── step-99-full-rollback.ps1
    └── proof/                 <- captured evidence (gitignored)
```

## The two-track model

| Track | Input | Risk |
|------|-------|------|
| `scripts/` | `config/customer.psd1` filled in once | Higher — touches real prod MG and Foundry RGs |
| `test-harness/` | `config/pilot-test.psd1` (pre-filled, dev tenant only) | Low — synthetic MG, Audit only, self-cleaning |

The test harness **wraps** the rollout scripts. It does not duplicate them. Bug
fixes happen once in `scripts/`; both tracks pick them up.

## Workflow

```
   ┌──────────────────────────────┐
   │ 1. edit / add a script       │
   │    in rollout/scripts/       │
   └──────────────┬───────────────┘
                  ↓
   ┌──────────────────────────────┐
   │ 2. run the matching          │
   │    step-NN in a sandbox      │
   │    tenant                    │
   └──────────────┬───────────────┘
                  ↓
       PASS ────────── FAIL ──→ fix scripts/, re-run step-NN
        │
        ↓
   ┌──────────────────────────────┐
   │ 3. capture proof/ files      │
   │    for review                │
   └──────────────┬───────────────┘
                  ↓
   ┌──────────────────────────────┐
   │ 4. fill in customer.psd1     │
   │    and run scripts/00..30    │
   │    in the production tenant  │
   └──────────────────────────────┘
```

## Status

| Track | scripts/ | test-harness/ | Notes |
|-------|----------|---------------|-------|
| MG policy | ready | ready | Default effect=Audit. Deny is exercised via a temporary RG-scoped assignment in step 05. |
| Notifications | ready | ready | Logic App posts an Adaptive Card to Teams via Workflows Incoming Webhook. Logic App is Consumption-priced — cost only on trigger. |
| Shadow-AI / Conditional Access | stub | n/a | Designed but not implemented. See `scripts/40-shadow-ai-ca.ps1` for the open questions. |

See `customer-runbook.md` for the production sequence.
See `test-harness/README.md` for the sandbox sequence and proof capture.
