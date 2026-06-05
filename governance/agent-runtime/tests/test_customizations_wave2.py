"""Wave 2 KLZ deltas: production.yaml + data-protection.yaml + klz-production composition."""
from __future__ import annotations

import pytest

from loader import compose_policy, load_policy_yaml


def _named_policy(policy: dict, name: str) -> dict:
    for p in policy.get("policies", []):
        if p.get("name") == name:
            return p
    raise AssertionError(
        f"policy named '{name}' not found in {[p.get('name') for p in policy.get('policies', [])]}"
    )


# -----------------------------------------------------------------------------
# production.yaml — KLZ deltas vs upstream
# -----------------------------------------------------------------------------
class TestProductionCustomizations:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("production")

    def test_tool_allowlist_is_azure_only(self, policy):
        p = _named_policy(policy, "tool_allowlist")
        http = next(
            a for a in p["allow"] if a.get("action") == "http_request"
        )
        domains = set(http["domains"])
        assert "apim-klzfin-*.azure-api.net" in domains
        assert "*.cognitiveservices.azure.com" in domains
        assert "*.openai.azure.com" in domains
        # No public AI endpoints in KLZ prod allowlist.
        assert "api.openai.com" not in domains
        assert "api.anthropic.com" not in domains
        assert "*.company.com" not in domains

    def test_network_allowlist_is_azure_only(self, policy):
        p = _named_policy(policy, "network_allowlist")
        http = next(
            a for a in p["allow"] if a.get("action") == "http_request"
        )
        domains = set(http["domains"])
        # Same Azure-only set as tool_allowlist.
        assert "apim-klzfin-*.azure-api.net" in domains
        assert "*.cognitiveservices.azure.com" in domains
        # Default-deny enforced.
        assert any(d.get("domains") == ["*"] for d in p["deny"])
        assert p["action"] == "SIGKILL"

    def test_llm_rate_limits_tighter_than_upstream(self, policy):
        p = _named_policy(policy, "strict_rate_limits")
        llm = next(l for l in p["limits"] if l.get("action") == "llm_call")
        # KLZ: 20/min (tighter than upstream's 30/min).
        assert llm["max_per_minute"] == 20
        assert llm["max_per_hour"] == 300

    def test_max_tokens_raised_for_gpt4o(self, policy):
        p = _named_policy(policy, "resource_limits")
        tokens = next(l for l in p["limits"] if "max_tokens_per_call" in l)
        # KLZ raised from upstream 4000 -> 8000 for gpt-4o context window.
        assert tokens["max_tokens_per_call"] == 8000

    def test_audit_export_targets_azure(self, policy):
        dests = policy["audit"]["export"]["destinations"]
        types = [d["type"] for d in dests]
        assert "log_analytics" in types
        assert "application_insights" in types
        assert "opentelemetry" in types
        # Find the LAW destination by name; it must reference KlzAgentAudit_CL.
        law = next(d for d in dests if d["type"] == "log_analytics")
        assert law["custom_table"] == "KlzAgentAudit_CL"

    def test_block_write_operations_requires_sre_approval(self, policy):
        p = _named_policy(policy, "block_write_operations")
        assert p["requires_approval"] is True
        assert p["approval_level"] == "sre_team"
        assert p["action"] == "SIGKILL"

    def test_sensitive_tool_approval_has_sod_tiers(self, policy):
        p = _named_policy(policy, "sensitive_tool_approval")
        levels = {a["approval_level"] for a in p["requires_approval"]}
        # SoD model required by SOX-style separation-of-duty checks.
        assert levels >= {
            "dba_team",
            "release_manager",
            "sre_team",
            "privacy_officer",
            "finance_team",
            "platform_team",
        }

    def test_strict_settings(self, policy):
        s = policy["settings"]
        assert s["fail_closed"] is True
        assert s["human_approval_required"] is True
        assert s["debug_mode"] is False
        assert s["auto_continue_on_warn"] is False


# -----------------------------------------------------------------------------
# data-protection.yaml — KLZ deltas vs upstream
# -----------------------------------------------------------------------------
class TestDataProtectionCustomizations:
    @pytest.fixture
    def policy(self):
        return load_policy_yaml("data-protection")

    def test_klz_azure_secret_protection_present(self, policy):
        p = _named_policy(policy, "klz_azure_secret_protection")
        assert p["severity"] == "critical"
        assert p["action"] == "SIGKILL"
        # scope is output-only by design.
        assert p["scope"] == ["output"]

    def test_data_retention_demoted_to_low_severity(self, policy):
        p = _named_policy(policy, "data_retention_warnings")
        # KLZ demoted from upstream "medium" to "low" — false-positive heavy.
        assert p["severity"] == "low"

    def test_compliance_frameworks_include_soc2(self, policy):
        frameworks = policy["compliance"]["frameworks"]
        assert "SOC2" in frameworks
        assert "GDPR" in frameworks
        assert "HIPAA" in frameworks
        # PCI-DSS is intentionally opt-in via Wave 3.
        assert "PCI-DSS" not in frameworks

    def test_data_classification_includes_azure_secrets(self, policy):
        cls = policy["compliance"]["data_classification"]
        assert "azure_subscription_id" in cls["confidential"]
        assert "azure_storage_key" in cls["restricted"]
        assert "sas_token" in cls["restricted"]

    def test_pii_detection_retains_upstream_patterns(self, policy):
        p = _named_policy(policy, "pii_detection")
        # Sanity: upstream SSN + CC patterns survived the fork.
        patterns = p["deny"][0]["patterns"]
        joined = "\n".join(patterns)
        assert r"\b\d{3}-\d{2}-\d{4}\b" in joined  # SSN
        assert "4[0-9]{12}" in joined              # Visa


# -----------------------------------------------------------------------------
# klz-production.yaml — composition + KLZ-only policies
# -----------------------------------------------------------------------------
class TestKlzProductionComposition:
    @pytest.fixture
    def composed(self):
        return compose_policy("klz-production")

    @pytest.fixture
    def raw(self):
        return load_policy_yaml("klz-production")

    def test_include_chain(self, raw):
        # Order matters for right-wins merge semantics.
        assert raw["include"] == [
            "enterprise",
            "api-gateway",
            "production",
            "data-protection",
        ]
        assert "cost-controls" not in raw["include"]

    def test_compose_yields_kernel_mode_strict(self, composed):
        assert composed["kernel"]["mode"] == "strict"
        # Right-most include / final overlay wins on `template`.
        assert composed["kernel"]["template"] == "klz-production"

    def test_prod_spend_cap_present(self, composed):
        p = _named_policy(composed, "klz_prod_spend_cap")
        assert p["spend_limit"]["daily_limit_usd"] == 100
        assert p["spend_limit"]["monthly_limit_usd"] == 2500
        assert p["spend_limit"]["provider"] == "azure_openai"

    def test_prod_model_allowlist_matches_klz(self, composed):
        p = _named_policy(composed, "klz_prod_model_allowlist")
        allowed = set(p["model_whitelist"]["allowed_models"])
        assert allowed == {"gpt-4o-mini", "gpt-4o", "text-embedding-3-large", "o3-mini"}
        blocked = set(p["model_whitelist"]["blocked_models"])
        assert "gpt-4-turbo" in blocked
        assert "claude-3-opus" in blocked
        assert "gemini-pro" in blocked

    def test_chargeback_headers_inherited_via_reassertion(self, composed):
        p = _named_policy(composed, "klz_required_chargeback_headers")
        assert set(p["require_headers"]) == {
            "x-project-name",
            "x-use-case",
            "x-cost-center",
        }

    def test_apim_only_egress_inherited_via_reassertion(self, composed):
        p = _named_policy(composed, "klz_apim_only_egress")
        assert p["action"] == "SIGKILL"
        assert p["severity"] == "critical"

    def test_compose_unions_signals_from_production(self, composed):
        signals = set(composed["signals"]["enabled"])
        # production.yaml contributes SIGUSR1 + SIGUSR2 that enterprise lacks.
        assert "SIGUSR1" in signals
        assert "SIGUSR2" in signals
        assert "SIGSTOP" in signals
        assert "SIGKILL" in signals
        assert "SIGCONT" in signals

    def test_no_duplicate_policy_names(self, composed):
        names = [p["name"] for p in composed["policies"]]
        assert len(names) == len(set(names)), (
            f"duplicate policy names: {[n for n in names if names.count(n) > 1]}"
        )

    def test_settings_are_fail_closed(self, composed):
        s = composed["settings"]
        assert s["fail_closed"] is True
        assert s["human_approval_required"] is True
        assert s["debug_mode"] is False
