# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
"""Unit tests for governance.agent_runtime.runtime.klz_client."""
from __future__ import annotations

import json
from typing import Any

import pytest

from runtime.klz_client import (
    AuditWriter,
    KlzClient,
    KlzConfig,
    PolicyDecision,
    PolicyViolation,
    RawResponse,
)


# -----------------------------------------------------------------------------
# Test fixtures
# -----------------------------------------------------------------------------
def _config() -> KlzConfig:
    return KlzConfig(
        apim_gateway="https://apim-klzfin-dev-c6ej.azure-api.net",
        apim_subscription_key="test-key",
        dce_endpoint="https://dce-klzfin.eastus2-1.ingest.monitor.azure.com",
        dcr_immutable_id="dcr-abc123",
        agent_name="unit-test-agent",
        agent_version="1.0.0",
        region="eastus2",
    )


class _Recorder:
    """Captures every audit row + every upstream request."""

    def __init__(self) -> None:
        self.audit_rows: list[dict[str, Any]] = []
        self.requests: list[tuple[str, str, dict[str, str], dict[str, Any]]] = []

    def transport(self, method: str, url: str, headers, body) -> RawResponse:
        self.requests.append((method, url, dict(headers), body))
        return RawResponse(
            status=200,
            headers={"content-type": "application/json"},
            body={
                "id": "chatcmpl-1",
                "model": body.get("model", "gpt-4o-mini"),
                "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20},
                "choices": [{"message": {"content": "ok"}}],
            },
        )

    def poster(self, url: str, headers, rows) -> int:
        self.audit_rows.extend(rows)
        return 204


def _client(
    policy: dict[str, Any] | None = None,
    *,
    config: KlzConfig | None = None,
) -> tuple[KlzClient, _Recorder]:
    cfg = config or _config()
    rec = _Recorder()
    writer = AuditWriter(cfg, token_provider=lambda: "tok", poster=rec.poster)
    client = KlzClient(
        config=cfg,
        transport=rec.transport,
        apim_token_provider=lambda: "apim-tok",
        audit_writer=writer,
        policy=policy or {"kernel": {"version": "1.0"}, "policies": []},
    )
    return client, rec


# -----------------------------------------------------------------------------
# Allow path
# -----------------------------------------------------------------------------
def test_invoke_with_no_policies_allows_and_audits():
    client, rec = _client()
    decision, response = client.invoke(
        method="POST",
        path="/openai/deployments/gpt-4o-mini/chat/completions",
        headers={
            "x-project-name": "demo",
            "x-use-case": "qa",
            "x-cost-center": "CC-1000",
        },
        body={"messages": [{"role": "user", "content": "hi"}], "model": "gpt-4o-mini"},
        model="gpt-4o-mini",
    )
    assert decision.is_allowed
    assert decision.decision == "allow"
    assert decision.violations == []
    assert response is not None
    assert response.status == 200
    assert len(rec.requests) == 1
    assert len(rec.audit_rows) == 1
    row = rec.audit_rows[0]
    assert row["Decision"] == "allow"
    assert row["ProjectName"] == "demo"
    assert row["CostCenter"] == "CC-1000"
    assert row["PromptTokens"] == 12
    assert row["TotalTokens"] == 20
    assert row["HttpStatus"] == 200
    assert row["Model"] == "gpt-4o-mini"
    assert row["AgentName"] == "unit-test-agent"
    # AuditPayload is JSON; empty violations
    payload = json.loads(row["AuditPayload"])
    assert payload["violations"] == []


def test_url_assembly_strips_double_slashes():
    client, rec = _client()
    client.invoke(
        method="GET",
        path="//health",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    method, url, _, _ = rec.requests[0]
    assert method == "GET"
    assert url == "https://apim-klzfin-dev-c6ej.azure-api.net/health"


def test_apim_subscription_key_injected_when_set():
    client, rec = _client()
    client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    _, _, headers, _ = rec.requests[0]
    assert headers["Ocp-Apim-Subscription-Key"] == "test-key"
    assert headers["Authorization"] == "Bearer apim-tok"


def test_apim_subscription_key_not_sent_when_none():
    cfg = _config()
    cfg.apim_subscription_key = None
    client, rec = _client(config=cfg)
    client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    _, _, headers, _ = rec.requests[0]
    assert "Ocp-Apim-Subscription-Key" not in headers


# -----------------------------------------------------------------------------
# Deny path: chargeback headers
# -----------------------------------------------------------------------------
_HEADER_POLICY = {
    "kernel": {"version": "1.0"},
    "policies": [
        {
            "name": "klz_required_chargeback_headers",
            "require_headers": ["x-project-name", "x-use-case", "x-cost-center"],
            "severity": "medium",
            "action": "SIGSTOP",
        }
    ],
}


def test_missing_chargeback_headers_blocks_and_audits():
    client, rec = _client(policy=_HEADER_POLICY)
    decision, response = client.invoke(
        method="POST",
        path="/openai/deployments/gpt-4o-mini/chat/completions",
        headers={},  # missing all three
        body={"messages": []},
        model="gpt-4o-mini",
    )
    assert decision.decision == "deny"
    assert not decision.is_allowed
    assert response is None
    assert rec.requests == []  # no upstream call
    assert len(rec.audit_rows) == 1
    row = rec.audit_rows[0]
    assert row["Decision"] == "deny"
    assert row["Signal"] == "chargeback_header_missing"
    assert row["ViolatedPolicy"] == "klz_required_chargeback_headers"
    assert "x-project-name" in row["ViolatedField"]


def test_partial_chargeback_headers_blocks():
    client, rec = _client(policy=_HEADER_POLICY)
    decision, _ = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p"},  # missing two
        body={},
    )
    assert decision.decision == "deny"
    primary = decision.primary_violation
    assert primary is not None
    assert "x-use-case" in primary.field
    assert "x-cost-center" in primary.field


def test_all_chargeback_headers_passes():
    client, rec = _client(policy=_HEADER_POLICY)
    decision, response = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    assert decision.is_allowed
    assert response is not None


# -----------------------------------------------------------------------------
# Deny path: egress allowlist
# -----------------------------------------------------------------------------
_EGRESS_POLICY = {
    "kernel": {"version": "1.0"},
    "policies": [
        {
            "name": "klz_apim_only_egress",
            "severity": "critical",
            "allow": [{"action": "http_request", "domains": ["*.azure-api.net"]}],
            "deny": [{"action": "http_request", "domains": ["*"]}],
            "action": "SIGKILL",
        }
    ],
}


def test_egress_blocks_non_allowed_host():
    cfg = _config()
    cfg.apim_gateway = "https://shady-llm.example.com"
    client, rec = _client(policy=_EGRESS_POLICY, config=cfg)
    decision, response = client.invoke(
        method="POST",
        path="/v1/chat",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    assert decision.decision == "deny"
    assert response is None
    primary = decision.primary_violation
    assert primary is not None
    assert primary.signal == "shadow_ai_egress"
    assert "shady-llm.example.com" in primary.reason


def test_egress_allows_apim_host():
    client, rec = _client(policy=_EGRESS_POLICY)
    decision, response = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
    )
    assert decision.is_allowed
    assert response is not None


# -----------------------------------------------------------------------------
# Deny path: model allowlist
# -----------------------------------------------------------------------------
_MODEL_POLICY = {
    "kernel": {"version": "1.0"},
    "policies": [
        {
            "name": "klz_model_allowlist",
            "severity": "high",
            "model_allowlist": ["gpt-4o-mini", "gpt-4o"],
            "action": "SIGSTOP",
        }
    ],
}


def test_disallowed_model_blocked():
    client, rec = _client(policy=_MODEL_POLICY)
    decision, response = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
        model="gpt-3.5-turbo",
    )
    assert decision.decision == "deny"
    assert response is None
    primary = decision.primary_violation
    assert primary is not None
    assert primary.signal == "model_not_allowed"


def test_allowed_model_passes():
    client, rec = _client(policy=_MODEL_POLICY)
    decision, _ = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
        model="gpt-4o-mini",
    )
    assert decision.is_allowed


def test_no_model_skips_model_check():
    client, _ = _client(policy=_MODEL_POLICY)
    decision, _ = client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
        model=None,
    )
    assert decision.is_allowed


# -----------------------------------------------------------------------------
# AuditWriter URL composition
# -----------------------------------------------------------------------------
def test_audit_writer_url_format():
    cfg = _config()
    captured: list[str] = []

    def poster(url: str, headers, rows) -> int:
        captured.append(url)
        return 204

    writer = AuditWriter(cfg, token_provider=lambda: "tok", poster=poster)
    writer.write({"hello": "world"})
    assert captured == [
        "https://dce-klzfin.eastus2-1.ingest.monitor.azure.com/dataCollectionRules/"
        "dcr-abc123/streams/Custom-KlzAgentAudit_CL?api-version=2023-01-01"
    ]


def test_audit_writer_strips_trailing_slash_from_dce():
    cfg = _config()
    cfg.dce_endpoint = "https://dce.example.com/"
    captured: list[str] = []

    def poster(url: str, headers, rows) -> int:
        captured.append(url)
        return 204

    AuditWriter(cfg, token_provider=lambda: "tok", poster=poster).write({})
    assert "//dataCollectionRules" not in captured[0]


# -----------------------------------------------------------------------------
# Decision math
# -----------------------------------------------------------------------------
def test_preflight_returns_correlation_id_from_header():
    client, _ = _client()
    decision = client.preflight(
        url="https://x.azure-api.net/y",
        headers={"x-correlation-id": "abc-123"},
        model=None,
    )
    assert decision.correlation_id == "abc-123"


def test_preflight_generates_correlation_id_when_missing():
    client, _ = _client()
    decision = client.preflight(
        url="https://x.azure-api.net/y",
        headers={},
        model=None,
    )
    assert decision.correlation_id
    assert len(decision.correlation_id) >= 8


def test_decision_helpers():
    d = PolicyDecision(decision="allow")
    assert d.is_allowed
    assert d.primary_violation is None

    v = PolicyViolation(
        policy="p", field="f", reason="r", severity="s",
        signal="sig", action="SIGSTOP",
    )
    d2 = PolicyDecision(decision="deny", violations=[v])
    assert not d2.is_allowed
    assert d2.primary_violation is v


def test_cost_estimator_called():
    cfg = _config()
    seen: list[tuple[str, int, int]] = []

    def estimator(model: str, p: int, c: int) -> float:
        seen.append((model, p, c))
        return 0.0042

    cfg.cost_estimator = estimator
    client, rec = _client(config=cfg)
    client.invoke(
        method="POST",
        path="/x",
        headers={"x-project-name": "p", "x-use-case": "u", "x-cost-center": "c"},
        body={},
        model="gpt-4o-mini",
    )
    assert seen == [("gpt-4o-mini", 12, 8)]
    assert rec.audit_rows[0]["EstimatedCostUsd"] == 0.0042
