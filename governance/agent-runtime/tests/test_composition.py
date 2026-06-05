"""Tests for `include:` composition semantics via compose_policy()."""
from __future__ import annotations

import pytest

from loader import compose_policy, load_policy_yaml


@pytest.fixture
def composed():
    return compose_policy("klz-baseline")


class TestComposeBasics:
    def test_include_directive_stripped(self, composed):
        assert "include" not in composed

    def test_kernel_overridden_by_klz_baseline(self, composed):
        # klz-baseline.yaml is the last layer — its kernel wins.
        assert composed["kernel"]["template"] == "klz-baseline"

    def test_settings_from_klz_baseline_present(self, composed):
        assert composed["settings"]["fail_closed"] is True
        assert composed["settings"]["human_approval_required"] is True


class TestPolicyUnion:
    def test_policies_from_all_three_includes_present(self, composed):
        names = {p["name"] for p in composed["policies"]}
        # From enterprise.yaml
        assert "credential_protection" in names
        assert "pii_protection" in names
        assert "high_risk_operations" in names
        # From api-gateway.yaml
        assert "url_validation" in names
        assert "header_validation" in names
        # From cost-controls.yaml
        assert "model_tier_control" in names
        assert "daily_spend_limit" in names
        # From klz-baseline.yaml (the new layer)
        assert "klz_required_chargeback_headers" in names
        assert "klz_apim_only_egress" in names

    def test_no_duplicate_policy_names(self, composed):
        names = [p["name"] for p in composed["policies"]]
        assert len(names) == len(set(names)), (
            f"composition produced duplicate policy names: "
            f"{[n for n in names if names.count(n) > 1]}"
        )

    def test_policy_count_reasonable(self, composed):
        # Sanity check: enterprise (~10) + api-gateway (~8) + cost-controls (~8) + klz (2)
        # No duplicates, so somewhere around 25-30.
        assert 20 <= len(composed["policies"]) <= 40


class TestSignalsUnion:
    def test_signals_unioned_from_enterprise(self, composed):
        # enterprise.yaml ships the canonical SIGSTOP/KILL/CONT/USR1/USR2 set.
        signals = composed["signals"]["enabled"]
        for s in ["SIGSTOP", "SIGKILL", "SIGCONT", "SIGUSR1", "SIGUSR2"]:
            assert s in signals


class TestNetworkBlockMerge:
    def test_blocklist_unioned(self, composed):
        blocklist = composed["network"]["blocklist"]
        # api-gateway.yaml blocks these:
        for b in ["api.openai.com", "*.onion", "pastebin.com"]:
            assert b in blocklist

    def test_allowlist_unioned(self, composed):
        allowlist = composed["network"]["allowlist"]
        assert "apim-klzfin-dev-c6ej.azure-api.net" in allowlist
        assert "*.cognitiveservices.azure.com" in allowlist

    def test_default_action_deny(self, composed):
        assert composed["network"]["default_action"] == "deny"


class TestCostTrackingPreserved:
    def test_cost_tracking_dimensions_intact(self, composed):
        # cost-controls.yaml is included — its top-level cost_tracking block
        # should survive composition.
        dims = composed["cost_tracking"]["dimensions"]
        assert "project_name" in dims
        assert "cost_center" in dims


class TestCycleDetection:
    def test_cycle_raises_value_error(self, tmp_path, monkeypatch):
        # Create a fake circular include chain in a temp policies dir.
        from loader import _POLICIES_DIR  # noqa: PLC0415

        # We can't easily monkeypatch the module-level constant safely without
        # making the whole loader configurable, so this test just confirms
        # the cycle-detection branch is reachable via _seen guard.
        from loader import compose_policy as _compose  # noqa: PLC0415

        # Bypass: feed a "_seen" that already contains the target.
        with pytest.raises(ValueError, match="Include cycle detected"):
            _compose("enterprise", _seen={"enterprise"})


class TestComposedDataMatchesParts:
    """Sanity: each unioned policy should equal its source-file definition."""

    def test_klz_required_headers_equals_baseline_definition(self, composed):
        baseline = load_policy_yaml("klz-baseline")
        baseline_policy = next(
            p for p in baseline["policies"] if p["name"] == "klz_required_chargeback_headers"
        )
        composed_policy = next(
            p for p in composed["policies"] if p["name"] == "klz_required_chargeback_headers"
        )
        assert composed_policy == baseline_policy

    def test_model_tier_control_equals_cost_controls_definition(self, composed):
        cc = load_policy_yaml("cost-controls")
        cc_policy = next(p for p in cc["policies"] if p["name"] == "model_tier_control")
        composed_policy = next(p for p in composed["policies"] if p["name"] == "model_tier_control")
        assert composed_policy == cc_policy
