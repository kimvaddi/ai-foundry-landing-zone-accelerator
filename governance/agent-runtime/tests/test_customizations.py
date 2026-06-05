"""Tests asserting the KLZ-specific deltas vs upstream are present.

If these fail, the fork has drifted from the KLZ requirements documented
in the per-file header blocks under `policies/` and `loader.py`.
"""
from __future__ import annotations

import pytest

from loader import load_policy_yaml


# -----------------------------------------------------------------------------
# cost-controls.yaml
# -----------------------------------------------------------------------------
class TestCostControlsCustomizations:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("cost-controls")

    def test_only_azure_openai_provider(self, policy):
        providers = policy["rate_limits"]["providers"]
        assert set(providers.keys()) == {"azure_openai"}, (
            "KLZ uses Azure OpenAI via Foundry only — public anthropic/google removed"
        )

    def test_dev_daily_spend_cap_is_25(self, policy):
        # Provider-level
        assert policy["rate_limits"]["providers"]["azure_openai"]["daily_spend_limit_usd"] == 25.0
        # Policy-level
        daily = _named_policy(policy, "daily_spend_limit")
        assert daily["daily_limit_usd"] == 25.0

    def test_model_allowlist_matches_klz_deployments(self, policy):
        ctrl = _named_policy(policy, "model_tier_control")
        assert set(ctrl["allowed_models"]) == {
            "gpt-4o-mini",
            "gpt-4o",
            "text-embedding-3-large",
            "o3-mini",
        }

    def test_model_blocklist_includes_non_klz_models(self, policy):
        ctrl = _named_policy(policy, "model_tier_control")
        for blocked in ["gpt-4-turbo", "claude-3-opus", "gemini-pro"]:
            assert blocked in ctrl["blocked_models"]

    def test_cost_tracking_dimensions_match_chargeback_schema(self, policy):
        dims = policy["cost_tracking"]["dimensions"]
        # Phase A.5 chargeback headers
        for required in ["project_name", "use_case", "cost_center", "subscription_id"]:
            assert required in dims, (
                f"missing dimension '{required}' — required by chargeback KQL"
            )

    def test_opentelemetry_export_configured(self, policy):
        otel = policy["cost_tracking"]["metrics"]["opentelemetry"]
        assert otel["enabled"] is True
        assert "${OTEL_EXPORTER_OTLP_ENDPOINT}" in otel["endpoint"]

    def test_monthly_budget_is_dev_cap(self, policy):
        assert policy["budget_reset"]["monthly_budget_usd"] == 750.0


# -----------------------------------------------------------------------------
# api-gateway.yaml
# -----------------------------------------------------------------------------
class TestApiGatewayCustomizations:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("api-gateway")

    def test_allowlist_contains_klz_apim_fqdn(self, policy):
        allowlist = policy["network"]["allowlist"]
        assert "apim-klzfin-dev-c6ej.azure-api.net" in allowlist

    def test_allowlist_excludes_public_ai_endpoints(self, policy):
        allowlist = policy["network"]["allowlist"]
        for public_endpoint in [
            "api.openai.com",
            "api.anthropic.com",
            "generativelanguage.googleapis.com",
            "api.groq.com",
        ]:
            assert public_endpoint not in allowlist, (
                f"{public_endpoint} should NOT be in allowlist — agents route via APIM"
            )

    def test_blocklist_contains_public_ai_endpoints(self, policy):
        blocklist = policy["network"]["blocklist"]
        for blocked in ["api.openai.com", "api.anthropic.com"]:
            assert blocked in blocklist

    def test_default_action_is_deny(self, policy):
        assert policy["network"]["default_action"] == "deny"

    def test_no_localhost_exception(self, policy):
        url_val = _named_policy(policy, "url_validation")
        assert url_val.get("exceptions") == []

    def test_tls_min_version_is_13(self, policy):
        assert policy["tls"]["min_version"] == "1.3"


# -----------------------------------------------------------------------------
# enterprise.yaml
# -----------------------------------------------------------------------------
class TestEnterpriseCustomizations:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("enterprise")

    def test_network_restrictions_only_azure_endpoints(self, policy):
        net = _named_policy(policy, "network_restrictions")
        allow_block = net["allow"][0]
        assert allow_block["action"] == "http_request"
        domains = set(allow_block["domains"])
        # Must contain only Azure-managed domains.
        for d in domains:
            assert d.endswith(
                (
                    ".azure-api.net",
                    ".cognitiveservices.azure.com",
                    ".openai.azure.com",
                    ".blob.core.windows.net",
                )
            ), f"non-Azure domain '{d}' leaked into network_restrictions"

    def test_cost_cap_matches_cost_controls(self, policy):
        cc = _named_policy(policy, "cost_controls")
        llm_limits = next(l for l in cc["limits"] if "max_cost_per_day_usd" in l)
        assert llm_limits["max_cost_per_day_usd"] == 25, (
            "must match daily_spend_limit in cost-controls.yaml"
        )

    def test_observability_uses_otel_env_var(self, policy):
        otel = policy["integrations"]["observability"]["opentelemetry"]
        assert otel["enabled"] is True
        assert "${OTEL_EXPORTER_OTLP_ENDPOINT}" in otel["endpoint"]

    def test_audit_export_to_log_analytics(self, policy):
        exports = policy["audit"]["export"]["destinations"]
        types = [d["type"] for d in exports]
        assert "log_analytics" in types
        assert "opentelemetry" in types

    def test_sso_provider_is_entra(self, policy):
        assert policy["integrations"]["sso"]["provider"] == "entra"

    def test_secrets_manager_is_key_vault(self, policy):
        assert policy["integrations"]["secrets_manager"]["provider"] == "key_vault"


# -----------------------------------------------------------------------------
# klz-baseline.yaml (new composition policy)
# -----------------------------------------------------------------------------
class TestKlzBaselineFile:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("klz-baseline")

    def test_includes_three_upstream_templates(self, policy):
        assert policy["include"] == ["enterprise", "api-gateway", "cost-controls"]

    def test_adds_required_chargeback_headers_policy(self, policy):
        p = _named_policy(policy, "klz_required_chargeback_headers")
        assert set(p["require_headers"]) == {
            "x-project-name",
            "x-use-case",
            "x-cost-center",
        }

    def test_adds_apim_only_egress_policy(self, policy):
        p = _named_policy(policy, "klz_apim_only_egress")
        assert p["action"] == "SIGKILL"
        assert p["severity"] == "critical"

    def test_fail_closed(self, policy):
        assert policy["settings"]["fail_closed"] is True
        assert policy["settings"]["human_approval_required"] is True


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
def _named_policy(policy: dict, name: str) -> dict:
    """Return the named policy entry or fail loudly."""
    for p in policy.get("policies", []):
        if p.get("name") == name:
            return p
    raise AssertionError(
        f"policy named '{name}' not found in {[p.get('name') for p in policy.get('policies', [])]}"
    )
