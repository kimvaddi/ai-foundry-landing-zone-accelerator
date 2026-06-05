"""Wave 2 end-to-end semantics: the composed klz-production policy denies the
right things and allows the right things via the synthetic test evaluator.

Mirrors tests/test_policy_semantics.py for Wave 1 but targets compose_policy("klz-production").
"""
from __future__ import annotations

import pytest

from loader import compose_policy
from tests._engine import evaluate_http_request, evaluate_model_call


@pytest.fixture(scope="module")
def prod():
    """Composed klz-production policy used by every test in this module."""
    return compose_policy("klz-production")


# -----------------------------------------------------------------------------
# Network allowlist semantics
# -----------------------------------------------------------------------------
class TestProdNetworkAllowlist:
    def test_apim_klz_allowed(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://apim-klzfin-prod-c6ej.azure-api.net/v1/chat",
            headers={
                "x-project-name": "demo",
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert d.allowed, d.reason

    def test_azure_openai_allowed(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://aif-klzfin-prod-c6ej.cognitiveservices.azure.com/openai/v1/chat",
            headers={
                "x-project-name": "demo",
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert d.allowed, d.reason

    def test_public_openai_denied(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://api.openai.com/v1/chat/completions",
            headers={
                "x-project-name": "demo",
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert not d.allowed
        # Shadow-AI must be caught — either by blocklist (explicit deny) or
        # by allowlist+default_action=deny.
        reason = d.reason.lower()
        assert "blocklist" in reason or "allowlist" in reason or "not in" in reason

    def test_anthropic_denied(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://api.anthropic.com/v1/messages",
            headers={
                "x-project-name": "demo",
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert not d.allowed

    def test_arbitrary_domain_denied(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://attacker.example.com/exfil",
            headers={
                "x-project-name": "demo",
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert not d.allowed


# -----------------------------------------------------------------------------
# Chargeback header semantics (inherited from klz_required_chargeback_headers)
# -----------------------------------------------------------------------------
class TestProdChargebackHeaders:
    def test_missing_project_name_denied(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://apim-klzfin-prod-c6ej.azure-api.net/v1/chat",
            headers={
                "x-use-case": "demo",
                "x-cost-center": "CC-DEMO",
            },
        )
        assert not d.allowed
        assert "x-project-name" in d.reason

    def test_missing_all_three_headers_denied(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://apim-klzfin-prod-c6ej.azure-api.net/v1/chat",
            headers={},
        )
        assert not d.allowed
        for h in ("x-project-name", "x-use-case", "x-cost-center"):
            assert h in d.reason

    def test_case_insensitive_header_match(self, prod):
        d = evaluate_http_request(
            prod,
            url="https://apim-klzfin-prod-c6ej.azure-api.net/v1/chat",
            headers={
                "X-Project-Name": "demo",
                "X-Use-Case": "demo",
                "X-Cost-Center": "CC-DEMO",
            },
        )
        assert d.allowed, d.reason


# -----------------------------------------------------------------------------
# Prod spend cap ($100/day)
# -----------------------------------------------------------------------------
class TestProdSpendCap:
    def test_well_under_cap_allowed(self, prod):
        d = evaluate_model_call(
            prod, model="gpt-4o-mini", cost_usd=0.05, daily_spend_so_far_usd=12.34
        )
        assert d.allowed, d.reason

    def test_at_boundary_allowed(self, prod):
        # 99.99 + 0.01 = 100.00 — equals cap, allowed (cap is "would exceed").
        d = evaluate_model_call(
            prod, model="gpt-4o-mini", cost_usd=0.01, daily_spend_so_far_usd=99.99
        )
        assert d.allowed, d.reason

    def test_just_over_cap_denied(self, prod):
        d = evaluate_model_call(
            prod, model="gpt-4o-mini", cost_usd=0.02, daily_spend_so_far_usd=99.99
        )
        assert not d.allowed
        # Either dev daily_spend_limit OR klz_prod_spend_cap will fire — but
        # since cost-controls is NOT in the prod composition, only the prod cap
        # at $100 should trip here.
        assert "100" in d.reason or "spend" in d.reason.lower()

    def test_way_over_cap_denied(self, prod):
        d = evaluate_model_call(
            prod, model="gpt-4o", cost_usd=50.0, daily_spend_so_far_usd=80.0
        )
        assert not d.allowed


# -----------------------------------------------------------------------------
# Prod model allowlist
# -----------------------------------------------------------------------------
class TestProdModelAllowlist:
    @pytest.mark.parametrize(
        "model",
        ["gpt-4o-mini", "gpt-4o", "text-embedding-3-large", "o3-mini"],
    )
    def test_klz_deployed_models_allowed(self, prod, model):
        d = evaluate_model_call(prod, model=model, cost_usd=0.01, daily_spend_so_far_usd=0.0)
        assert d.allowed, d.reason

    @pytest.mark.parametrize(
        "model",
        ["claude-3-opus", "claude-3-sonnet", "gemini-pro", "llama-3", "mistral-large", "gpt-4-turbo"],
    )
    def test_non_azure_models_blocked(self, prod, model):
        d = evaluate_model_call(prod, model=model, cost_usd=0.01, daily_spend_so_far_usd=0.0)
        assert not d.allowed
        assert "block" in d.reason.lower() or "allow" in d.reason.lower()

    def test_unknown_model_blocked(self, prod):
        # Not in allowed_models -> denied by whitelist semantics.
        d = evaluate_model_call(
            prod, model="random-experimental-model", cost_usd=0.01, daily_spend_so_far_usd=0.0
        )
        assert not d.allowed
