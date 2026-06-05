# =============================================================================
# TEST FIXTURE ONLY — NOT FOR PRODUCTION ENFORCEMENT.
# =============================================================================
# Minimal synthetic policy evaluator used by tests/test_policy_semantics.py
# to prove the forked YAMLs encode the intended semantics (deny / allow
# decisions match what the analysis doc promised).
#
# This is NOT a policy engine. The real enforcement runs inside the
# upstream agent-governance-toolkit agent-OS runtime, or whatever runtime
# the consuming team adopts. This file exists so that `pytest` can give us
# a green "the YAMLs work as designed" signal end-to-end.
#
# Scope (what this evaluator covers, deliberately minimal):
#   * URL allowlist / blocklist match (api-gateway, enterprise.network_restrictions)
#   * URL regex deny patterns (api-gateway.url_validation)
#   * URL regex credential-in-URL deny (api-gateway.credential_protection)
#   * Model whitelist / blacklist (cost-controls.model_tier_control)
#   * Daily spend cap (cost-controls.daily_spend_limit)
#   * Required header presence (klz-baseline.klz_required_chargeback_headers)
# =============================================================================
"""Synthetic policy evaluator (test fixture)."""
from __future__ import annotations

import fnmatch
import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse


@dataclass
class Decision:
    allowed: bool
    reason: str
    policy_name: str | None = None


def evaluate_http_request(
    policy: dict[str, Any],
    *,
    url: str,
    headers: dict[str, str] | None = None,
) -> Decision:
    """Evaluate an HTTP request against the loaded policy.

    Order matches what the upstream runtime would do conceptually:
        1. Network blocklist (FQDN glob match)             -> deny
        2. URL pattern denies (SSRF, file://, etc)          -> deny
        3. Credential-in-URL denies                         -> deny
        4. Network allowlist (FQDN glob match)              -> require allow
        5. Required headers                                 -> deny if missing
        6. Default action (deny if default_action == deny)
    """
    headers = headers or {}
    host = urlparse(url).hostname or ""

    network = policy.get("network", {})
    blocklist = network.get("blocklist", []) or []
    allowlist = network.get("allowlist", []) or []
    default_action = network.get("default_action", "allow")

    # 1. Blocklist
    for pattern in blocklist:
        if fnmatch.fnmatch(host, pattern):
            return Decision(False, f"host '{host}' matches blocklist '{pattern}'", "network_blocklist")

    # 2 + 3. Policy-level URL pattern denies
    for p in policy.get("policies", []):
        for deny_block in p.get("deny", []) or []:
            for pattern in (deny_block.get("patterns") or []):
                if re.search(pattern, url):
                    return Decision(False, f"URL matches deny pattern '{pattern}'", p.get("name"))

    # 4. Allowlist (only enforced if default_action == deny)
    if default_action == "deny":
        if not any(fnmatch.fnmatch(host, a) for a in allowlist):
            return Decision(False, f"host '{host}' not in allowlist; default_action=deny", "network_allowlist")

    # 5. Required headers (klz_required_chargeback_headers)
    for p in policy.get("policies", []):
        required = p.get("require_headers")
        if required:
            lower_headers = {k.lower(): v for k, v in headers.items()}
            missing = [h for h in required if h.lower() not in lower_headers]
            if missing:
                return Decision(False, f"missing required headers: {missing}", p.get("name"))

    return Decision(True, "allowed by policy", None)


def evaluate_model_call(
    policy: dict[str, Any],
    *,
    model: str,
    cost_usd: float = 0.0,
    daily_spend_so_far_usd: float = 0.0,
) -> Decision:
    """Evaluate a model call against cost-controls policies.

    Order:
        1. Daily spend cap (would-exceed = deny)
        2. Model blacklist
        3. Model whitelist (if defined, model must be in it)
    """
    for p in policy.get("policies", []):
        ptype = p.get("type")

        if ptype == "spend_limit":
            cap = p.get("daily_limit_usd")
            if cap is not None and (daily_spend_so_far_usd + cost_usd) > cap:
                return Decision(
                    False,
                    f"daily spend cap ${cap} would be exceeded "
                    f"(so-far=${daily_spend_so_far_usd}, this-request=${cost_usd})",
                    p.get("name"),
                )

        if ptype == "model_whitelist":
            blocked = p.get("blocked_models") or []
            if model in blocked:
                return Decision(False, f"model '{model}' is explicitly blocked", p.get("name"))
            allowed = p.get("allowed_models") or []
            if allowed and model not in allowed:
                return Decision(False, f"model '{model}' not in allowed_models {allowed}", p.get("name"))

    return Decision(True, "model call allowed", None)
