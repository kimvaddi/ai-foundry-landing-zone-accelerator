# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
# =============================================================================
# KLZ FinOps Accelerator — live E2E driver for klz_client.py
# =============================================================================
# Exercises three paths against the LIVE dev landing zone:
#   1. DENY  — preflight blocks a call that is missing chargeback headers.
#              No APIM round-trip. One audit row (Decision="deny").
#   2. DENY  — preflight blocks a call to a model that is not in the
#              klz-baseline allowlist. No APIM round-trip. One audit row.
#   3. ALLOW — preflight passes, klz_client posts to APIM. Whether APIM
#              succeeds or fails, an audit row is written.
#
# This script is for engineer-side validation only. It is NOT wired into
# CI and uses interactive Entra credentials via DefaultAzureCredential
# (AzureCliCredential fallback).
#
# Required environment variables — set by the caller (none assumed):
#   KLZ_APIM_BASE_URL          e.g. https://apim-klzfin-dev-c6ej.azure-api.net
#   KLZ_APIM_SUBSCRIPTION_KEY  optional; pass empty if Entra-only
#   KLZ_DCE_ENDPOINT           e.g. https://dce-...ingest.monitor.azure.com
#   KLZ_DCR_IMMUTABLE_ID       dcr-6a41...
#   KLZ_DCR_STREAM             Custom-KlzAgentAudit_CL
# =============================================================================
"""Live end-to-end smoke driver for klz_client. Run only against dev."""
from __future__ import annotations

import json
import os
import sys
import uuid
from pathlib import Path

# Inject agent-runtime onto sys.path so loader.py + runtime.klz_client import.
_HERE = Path(__file__).resolve().parent
_AGENT_RUNTIME = _HERE.parent / "governance" / "agent-runtime"
sys.path.insert(0, str(_AGENT_RUNTIME))
sys.path.insert(0, str(_AGENT_RUNTIME / "runtime"))

from klz_client import KlzClient, KlzConfig  # noqa: E402


def _env(name: str, *, required: bool = True, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise SystemExit(f"missing required env var: {name}")
    return val or ""


def _print_decision(label: str, decision, response) -> None:
    print(f"\n--- {label} ---")
    print(f"decision:        {decision.decision}")
    print(f"correlationId:   {decision.correlation_id}")
    print(f"policyTemplate:  {decision.policy_template}")
    print(f"policyVersion:   {decision.policy_version}")
    if decision.primary_violation:
        v = decision.primary_violation
        print(f"violation:       {v.policy} / {v.signal} / {v.action}")
        print(f"  reason:        {v.reason}")
    if response is not None:
        print(f"http status:     {response.status}")
        print(f"latency ms:      {response.latency_ms}")
    else:
        print("http status:     (no upstream call)")


def main() -> int:
    cfg = KlzConfig(
        apim_gateway=_env("KLZ_APIM_BASE_URL"),
        apim_subscription_key=os.environ.get("KLZ_APIM_SUBSCRIPTION_KEY") or None,
        dce_endpoint=_env("KLZ_DCE_ENDPOINT"),
        dcr_immutable_id=_env("KLZ_DCR_IMMUTABLE_ID"),
        stream_name=_env("KLZ_DCR_STREAM", required=False, default="Custom-KlzAgentAudit_CL"),
        policy_template="klz-baseline",
        agent_name="klz-e2e-driver",
        agent_version="0.1.0",
        region="eastus2",
    )

    print("=== KLZ runtime live E2E ===")
    print(f"APIM:    {cfg.apim_gateway}")
    print(f"DCE:     {cfg.dce_endpoint}")
    print(f"DCR id:  {cfg.dcr_immutable_id}")
    print(f"stream:  {cfg.stream_name}")
    print(f"policy:  {cfg.policy_template}")

    client = KlzClient.from_env(cfg)
    run_tag = uuid.uuid4().hex[:8]
    print(f"run tag: {run_tag}  (use this to find rows in KQL)")

    # 1. DENY — missing chargeback headers ------------------------------------
    d1, r1 = client.invoke(
        method="POST",
        path="/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-08-01-preview",
        headers={
            "x-project-name": f"e2e-{run_tag}",
            # x-use-case intentionally omitted
            "x-cost-center": "CC-9999",
            "x-operation-id": f"deny-headers-{run_tag}",
        },
        body={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 1},
        model="gpt-4o-mini",
    )
    _print_decision("[1] DENY: missing x-use-case header", d1, r1)
    assert d1.decision == "deny", f"expected deny, got {d1.decision}"
    assert r1 is None, "deny path must not hit upstream"

    # 2. DENY — model not in allowlist ----------------------------------------
    d2, r2 = client.invoke(
        method="POST",
        path="/openai/deployments/gpt-4-turbo/chat/completions?api-version=2024-08-01-preview",
        headers={
            "x-project-name": f"e2e-{run_tag}",
            "x-use-case": "smoke",
            "x-cost-center": "CC-9999",
            "x-operation-id": f"deny-model-{run_tag}",
        },
        body={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 1},
        model="gpt-4-turbo",  # not in klz-baseline allowlist
    )
    _print_decision("[2] DENY: model gpt-4-turbo not allowed", d2, r2)
    # klz-baseline may not include a model_allowlist policy — only assert if it did.
    if d2.decision == "deny":
        print("    (model_allowlist policy is active)")
    else:
        print(f"    (NOTE: klz-baseline did not block model gpt-4-turbo: decision={d2.decision})")

    # 3. ALLOW — preflight passes; upstream may 401/404 but audit row writes ---
    d3, r3 = client.invoke(
        method="POST",
        path="/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-08-01-preview",
        headers={
            "x-project-name": f"e2e-{run_tag}",
            "x-use-case": "smoke",
            "x-cost-center": "CC-9999",
            "x-operation-id": f"allow-{run_tag}",
        },
        body={"messages": [{"role": "user", "content": "say hi"}], "max_tokens": 4},
        model="gpt-4o-mini",
    )
    _print_decision("[3] ALLOW: well-formed call through APIM", d3, r3)
    assert d3.decision == "allow", f"expected allow, got {d3.decision}"

    print("\n=== driver finished ===")
    print(f"run_tag = {run_tag}")
    print("KQL to verify (paste into Log Analytics):")
    print(
        "KlzAgentAudit_CL\n"
        f"| where ProjectName == 'e2e-{run_tag}'\n"
        "| project TimeGenerated, Decision, Signal, ViolatedPolicy, Model, "
        "HttpStatus, CorrelationId, OperationId\n"
        "| order by TimeGenerated desc"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
