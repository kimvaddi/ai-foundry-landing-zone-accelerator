"""Tests for the loader module — discovery + raw YAML loading."""
from __future__ import annotations

import pytest

from loader import list_templates, load_policy_yaml


class TestListTemplates:
    def test_returns_all_klz_templates(self):
        names = list_templates()
        assert set(names) == {
            "api-gateway",
            "cost-controls",
            "data-protection",
            "enterprise",
            "klz-baseline",
            "klz-production",
            "production",
        }

    def test_sorted_alphabetically(self):
        names = list_templates()
        assert names == sorted(names)


class TestLoadPolicyYaml:
    @pytest.mark.parametrize(
        "name",
        [
            "api-gateway",
            "cost-controls",
            "data-protection",
            "enterprise",
            "klz-baseline",
            "klz-production",
            "production",
        ],
    )
    def test_loads_each_template_as_dict(self, name):
        data = load_policy_yaml(name)
        assert isinstance(data, dict)
        assert "kernel" in data
        assert data["kernel"]["template"] == name

    def test_missing_template_raises_helpful_error(self):
        with pytest.raises(FileNotFoundError) as exc:
            load_policy_yaml("does-not-exist")
        msg = str(exc.value)
        assert "does-not-exist" in msg
        # Helpful: lists what's actually available.
        assert "Available:" in msg
        assert "klz-baseline" in msg

    def test_each_template_has_strict_mode_kernel(self):
        for name in list_templates():
            data = load_policy_yaml(name)
            assert data["kernel"]["mode"] == "strict", (
                f"{name} should be strict mode for KLZ"
            )

    def test_klz_baseline_has_include_directive(self):
        data = load_policy_yaml("klz-baseline")
        assert data["include"] == ["enterprise", "api-gateway", "cost-controls"]

    def test_klz_production_has_include_directive(self):
        data = load_policy_yaml("klz-production")
        assert data["include"] == [
            "enterprise",
            "api-gateway",
            "production",
            "data-protection",
        ]
        # Prod intentionally does NOT include cost-controls (uses its own caps).
        assert "cost-controls" not in data["include"]
