"""End-to-end policy semantics tests.

These tests prove the composed klz-baseline policy actually denies / allows
the right things via the synthetic evaluator in `_engine.py`. They are the
green-light signal that the fork did what the analysis doc promised.
"""
from __future__ import annotations

import pytest

from _engine import evaluate_http_request, evaluate_model_call
from loader import compose_policy


@pytest.fixture(scope="module")
def policy():
    return compose_policy("klz-baseline")


# -----------------------------------------------------------------------------
# Shadow-AI prevention: public AI URLs are blocked at the agent runtime
# -----------------------------------------------------------------------------
class TestShadowAiPrevention:
    @pytest.mark.parametrize(
        "url",
        [
            "https://api.openai.com/v1/chat/completions",
            "https://api.anthropic.com/v1/messages",
            "https://generativelanguage.googleapis.com/v1/models/gemini-pro:generateContent",
            "https://api.groq.com/openai/v1/chat/completions",
        ],
    )
    def test_public_ai_endpoints_denied(self, policy, url):
        d = evaluate_http_request(
            policy,
            url=url,
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "cc-123",
            },
        )
        assert not d.allowed, f"public AI URL {url} should be denied"
        assert "blocklist" in d.reason or "allowlist" in d.reason

    def test_apim_gateway_allowed(self, policy):
        d = evaluate_http_request(
            policy,
            url="https://apim-klzfin-dev-c6ej.azure-api.net/openai/v1/chat/completions",
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "cc-123",
            },
        )
        assert d.allowed, f"APIM gateway should be allowed; got: {d.reason}"

    def test_azure_cognitive_services_allowed(self, policy):
        d = evaluate_http_request(
            policy,
            url="https://aif-klzfin-dev-c6ej.cognitiveservices.azure.com/openai/deployments/gpt-4o-mini/chat/completions",
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "cc-123",
            },
        )
        assert d.allowed, f"cognitiveservices.azure.com should be allowed; got: {d.reason}"


# -----------------------------------------------------------------------------
# SSRF prevention
# -----------------------------------------------------------------------------
class TestSsrfPrevention:
    @pytest.mark.parametrize(
        "url",
        [
            "http://localhost:8080/admin",
            "http://127.0.0.1/secrets",
            "http://169.254.169.254/metadata/identity/oauth2/token",   # IMDS
            "http://10.0.0.1/internal",
            "http://192.168.1.1/router",
            "file:///etc/passwd",
            "gopher://evil.example.com/",
        ],
    )
    def test_ssrf_attempts_denied(self, policy, url):
        d = evaluate_http_request(
            policy,
            url=url,
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "cc-123",
            },
        )
        assert not d.allowed, f"SSRF URL {url} should be denied"


# -----------------------------------------------------------------------------
# Credential leakage prevention
# -----------------------------------------------------------------------------
class TestCredentialLeakage:
    @pytest.mark.parametrize(
        "url",
        [
            "https://apim-klzfin-dev-c6ej.azure-api.net/v1/chat?api_key=sk-abc123",
            "https://apim-klzfin-dev-c6ej.azure-api.net/v1/chat?token=eyJabc",
            "https://apim-klzfin-dev-c6ej.azure-api.net/v1/chat?password=hunter2",
        ],
    )
    def test_credentials_in_url_denied(self, policy, url):
        d = evaluate_http_request(
            policy,
            url=url,
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "cc-123",
            },
        )
        assert not d.allowed, f"credential-in-URL {url} should be denied"


# -----------------------------------------------------------------------------
# Required chargeback headers (KLZ-specific addition)
# -----------------------------------------------------------------------------
class TestRequiredChargebackHeaders:
    def test_missing_all_chargeback_headers_denied(self, policy):
        d = evaluate_http_request(
            policy,
            url="https://apim-klzfin-dev-c6ej.azure-api.net/openai/v1/chat/completions",
            headers={"User-Agent": "klz-agent/1.0"},
        )
        assert not d.allowed
        assert "x-project-name" in d.reason
        assert "x-use-case" in d.reason
        assert "x-cost-center" in d.reason

    def test_missing_only_cost_center_denied(self, policy):
        d = evaluate_http_request(
            policy,
            url="https://apim-klzfin-dev-c6ej.azure-api.net/openai/v1/chat/completions",
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "demo",
                "x-use-case": "test",
                # x-cost-center deliberately missing
            },
        )
        assert not d.allowed
        assert "x-cost-center" in d.reason


# -----------------------------------------------------------------------------
# Model allowlist (cost-controls)
# -----------------------------------------------------------------------------
class TestModelAllowlist:
    @pytest.mark.parametrize(
        "model",
        ["gpt-4o-mini", "gpt-4o", "text-embedding-3-large", "o3-mini"],
    )
    def test_klz_deployed_models_allowed(self, policy, model):
        d = evaluate_model_call(policy, model=model, cost_usd=0.10)
        assert d.allowed, f"KLZ-deployed model {model} should be allowed; got: {d.reason}"

    @pytest.mark.parametrize(
        "model",
        ["gpt-4-turbo", "gpt-4", "claude-3-opus", "claude-3-sonnet", "gemini-pro"],
    )
    def test_non_klz_models_blocked(self, policy, model):
        d = evaluate_model_call(policy, model=model, cost_usd=0.10)
        assert not d.allowed, f"non-KLZ model {model} should be blocked"


# -----------------------------------------------------------------------------
# Daily spend cap
# -----------------------------------------------------------------------------
class TestDailySpendCap:
    def test_under_cap_allowed(self, policy):
        d = evaluate_model_call(
            policy,
            model="gpt-4o-mini",
            cost_usd=5.00,
            daily_spend_so_far_usd=10.00,
        )
        assert d.allowed

    def test_at_cap_boundary_allowed(self, policy):
        # exactly at the cap is allowed; over it isn't
        d = evaluate_model_call(
            policy,
            model="gpt-4o-mini",
            cost_usd=5.00,
            daily_spend_so_far_usd=20.00,
        )
        assert d.allowed

    def test_over_cap_denied(self, policy):
        d = evaluate_model_call(
            policy,
            model="gpt-4o-mini",
            cost_usd=10.00,
            daily_spend_so_far_usd=20.00,
        )
        assert not d.allowed
        assert "daily spend cap" in d.reason


# -----------------------------------------------------------------------------
# Combined realistic scenario
# -----------------------------------------------------------------------------
class TestRealisticAgentCall:
    def test_well_behaved_agent_request_passes_both_checks(self, policy):
        # 1. HTTP request to APIM with all headers + a request body
        http_decision = evaluate_http_request(
            policy,
            url="https://apim-klzfin-dev-c6ej.azure-api.net/openai/v1/chat/completions",
            headers={
                "User-Agent": "klz-agent/1.0",
                "x-project-name": "finops-demo",
                "x-use-case": "monthly-showback",
                "x-cost-center": "cc-fin-001",
                "Ocp-Apim-Subscription-Key": "(redacted)",
            },
        )
        assert http_decision.allowed, http_decision.reason

        # 2. Model call for the body's deployment
        model_decision = evaluate_model_call(
            policy,
            model="gpt-4o-mini",
            cost_usd=0.02,
            daily_spend_so_far_usd=0.50,
        )
        assert model_decision.allowed, model_decision.reason
