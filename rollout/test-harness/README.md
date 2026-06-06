# Test harness — sandbox tenant
==============================

These scripts execute the same rollout that runs in production, but against a
**synthetic** management-group hierarchy in a sandbox tenant. Each script is
numbered. Run in order. Each script is **reversible within the same harness**
(the final `step-99` returns the tenant to its original state).

## Pre-reqs
- Signed in as a tenant admin in the sandbox tenant.
- `az account show` returns the expected sandbox tenant id.
- A live FinOps deploy exists in the sandbox (`rg-klzfin-platform-dev`, `rg-klzfin-foundry-dev`).
- This folder's `../config/pilot-test.psd1` exists and matches the sandbox tenant.

## Order

| Step | Script | What it does | Reversible by |
|------|--------|--------------|---------------|
| 01 | `step-01-create-test-parent-mg.ps1` | Creates `mg-klz-test-platform` under Tenant Root. Mimics an intermediate Platform MG. | `step-99` |
| 02 | `step-02-run-mg-rollout.ps1` | Runs prereq -> ensure ailz MG -> move sub -> assign initiative (Audit). Uses pilot-test.psd1. | `step-99` |
| 03 | `step-03-verify-compliance.ps1` | Waits 30 min, then exports compliance state for the Foundry account to `proof/`. | n/a (read-only) |
| 04 | `step-04-test-teams-notification.ps1` | Prompts for a Teams webhook URL, deploys notifications=true, sends synthetic alert payload, verifies HTTP 200. | `-Teardown` switch |
| 05 | `step-05-test-deny-mode.ps1` | TEMPORARY assignment at sub scope only with effect=Deny. Tries to create a non-allowlisted model -> expects 403. Cleans up the temporary assignment. | self-cleaning |
| 99 | `step-99-full-rollback.ps1` | Runs `scripts/99-rollback-all.ps1` then deletes `mg-klz-test-platform`. | n/a (this IS the cleanup) |

## Proof artifacts

Each step writes to `proof/<step>/` for audit and review. Proof is
**.gitignored** — sanitize before sharing.

## Cost

Everything except step 04 is **free** (MG operations + policy don't cost
anything). Step 04 adds a Logic App in Consumption pricing — costs only on
trigger, so a single test run is < $0.01. Step 99 deletes the Logic App.
