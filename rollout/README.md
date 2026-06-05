# KLZ Accelerator — customer rollout package

This folder is the **single deliverable the customer runs against the Foundry tenant** to
get from "we have an installed accelerator" to "policy + notifications are
governing our AI Landing Zone."

It is also the package the test pilot uses to **prove every step works** in a
dev tenant *before* anything reaches the customer.

```
rollout/
├── README.md                  <- you are here
├── customer-runbook.md             <- the human-readable, copy-paste runbook for the customer
├── config/
│   ├── customer.psd1.template <- the customer copies + fills in (.psd1 is gitignored)
│   └── pilot-test.psd1          <- the test pilot's pre-filled config for the test harness
├── scripts/                   <- THE ROLLOUT — what the customer actually runs
│   ├── 00-preflight.ps1
│   ├── 10-mg-hierarchy-ensure.ps1
│   ├── 15-subscription-move-under-mg.ps1
│   ├── 20-mg-policy-assign.ps1
│   ├── 30-notifications-enable.ps1
│   ├── 40-shadow-ai-ca.ps1    <- stub, Phase C lands in a follow-up iteration
│   └── 99-rollback-all.ps1
└── test-harness/              <- THE TEST PILOT — what the test pilot runs in the pilot tenant
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

| Track | Audience | Input | Risk |
|------|----------|-------|------|
| `scripts/` | the customer | `config/customer.psd1` filled in once | Higher — touches real prod MG and Foundry RGs |
| `test-harness/` | the test pilot | `config/pilot-test.psd1` (pre-filled, dev tenant only) | Low — synthetic MG, Audit only, self-cleaning |

The test harness **wraps** the rollout scripts. It does not duplicate them. Bug
fixes happen once in `scripts/`; both tracks pick them up.

## Workflow

```
   ┌──────────────────────────────┐
   │ 1. the test pilot writes/edits a script │
   │    in rollout/scripts/       │
   └──────────────┬───────────────┘
                  ↓
   ┌──────────────────────────────┐
   │ 2. the test pilot runs the matching     │
   │    step-NN in the pilot tenant │
   └──────────────┬───────────────┘
                  ↓
       PASS ────────── FAIL ──→ fix scripts/, re-run step-NN
        │
        ↓
   ┌──────────────────────────────┐
   │ 3. the test pilot captures proof/ files │
   │    to demonstrate to the customer     │
   └──────────────┬───────────────┘
                  ↓
   ┌──────────────────────────────┐
   │ 4. the customer fills in customer.psd1│
   │    and runs scripts/00..30   │
   │    in the customer tenant    │
   └──────────────────────────────┘
```

## Status (this iteration)

| Phase | scripts/ ready | test-harness/ ready | Notes |
|-------|---------------|---------------------|-------|
| B.1 wave 2 — MG policy | YES | YES | Default effect=Audit. Deny tested via temporary RG-scoped assignment in step 05. |
| B.4 — Notifications | YES | YES | Logic App posts Adaptive Card to Teams via Workflows Incoming Webhook. Cost <$0.01 per test run. |
| Phase C — Shadow-AI / CA | STUB | n/a | Designed but not built. See `scripts/40-shadow-ai-ca.ps1` for open questions. |

See `customer-runbook.md` for the customer-facing sequence.
See `test-harness/README.md` for the test pilot's sequence and proof capture.
