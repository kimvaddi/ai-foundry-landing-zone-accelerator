# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
# =============================================================================
# KLZ FinOps Accelerator — agent-runtime policy loader
# =============================================================================
# Derived from:  microsoft/agent-governance-toolkit
#                agent-governance-python/agent-os/templates/policies/loader.py
# Commit:        6f94b69f4c524f5c87227db0609e3d28deba7fb7
# Upstream:      MIT License (c) Microsoft Corporation
#
# KLZ deltas vs upstream:
#   * Removed load_policy() (the GovernancePolicy dataclass projection).
#     That dataclass lives in agent_os.integrations.base which is part of
#     the upstream framework. KLZ uses the full-fidelity dict form only;
#     the dataclass projection is lossy and not suitable for runtime
#     enforcement.
#   * Added compose_policy() to resolve `include:` chains and merge.
#     The upstream loader doesn't ship include resolution — it's done by
#     the engine that consumes the loaded dict. Pulling it into the loader
#     keeps the rest of the system simple.
#   * Templates live in ./policies/, not ./ (cleaner repo layout).
# =============================================================================
"""KLZ policy template loader.

Two consumption modes:

    from governance.agent_runtime.loader import (
        list_templates,
        load_policy_yaml,
        compose_policy,
    )

    # Raw single template
    raw = load_policy_yaml("cost-controls")

    # Resolved composition (recursive `include:` merge)
    baseline = compose_policy("klz-baseline")

    # All available templates
    names = list_templates()
"""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml

_POLICIES_DIR = Path(__file__).parent / "policies"


# -----------------------------------------------------------------------------
# Discovery + raw load
# -----------------------------------------------------------------------------
def list_templates() -> list[str]:
    """Return sorted names of all policy YAML templates (no extension)."""
    return sorted(p.stem for p in _POLICIES_DIR.glob("*.yaml"))


def load_policy_yaml(name: str) -> dict[str, Any]:
    """Load a single policy template as a dict.

    Args:
        name: Template name without `.yaml` extension (e.g. ``"cost-controls"``).

    Returns:
        Parsed YAML content as a dict.

    Raises:
        FileNotFoundError: If no template with the given name exists.
        ValueError: If the YAML file is empty or not a mapping.
    """
    path = _POLICIES_DIR / f"{name}.yaml"
    if not path.exists():
        available = ", ".join(list_templates())
        raise FileNotFoundError(
            f"Policy template '{name}' not found in {_POLICIES_DIR}. "
            f"Available: {available}"
        )

    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f.read())

    if not isinstance(data, dict):
        raise ValueError(
            f"Expected YAML mapping in '{name}.yaml', got {type(data).__name__}"
        )

    return data


# -----------------------------------------------------------------------------
# Composition (`include:` chain resolution)
# -----------------------------------------------------------------------------
# Keys whose list values are UNIONED across includes (dedup-preserving).
# Everything else is replaced by the right-most file.
_UNION_LIST_KEYS = frozenset(
    {
        "policies",                                # named-policy list
        ("signals", "enabled"),                    # signal set
        ("network", "allowlist"),                  # FQDN allowlist
        ("network", "blocklist"),                  # FQDN blocklist
    }
)


def compose_policy(name: str, _seen: set[str] | None = None) -> dict[str, Any]:
    """Resolve `include:` chains and return the composed policy dict.

    Composition order: left-to-right within ``include:``, then the current
    file's own keys overlay on top.

    Merge semantics:
      * Scalars / non-list values  -> right wins (last write).
      * Lists in _UNION_LIST_KEYS  -> unioned, preserving first-seen order,
                                       dedup by `name` for ``policies:``.
      * Other lists                 -> replaced (right wins).
      * Dicts                       -> recursively deep-merged.

    Args:
        name: Template name (no extension).
        _seen: Internal — cycle detection. Do not pass.

    Returns:
        Fully-composed policy dict with `include:` key stripped.

    Raises:
        ValueError: If a cycle is detected in include chain.
    """
    _seen = _seen or set()
    if name in _seen:
        raise ValueError(f"Include cycle detected at '{name}'. Chain: {_seen}")
    _seen = _seen | {name}

    raw = load_policy_yaml(name)
    includes: list[str] = list(raw.get("include", []))

    # Start from empty; layer each include in order.
    composed: dict[str, Any] = {}
    for inc_name in includes:
        included = compose_policy(inc_name, _seen=_seen)
        composed = _merge(composed, included)

    # Overlay the current file (minus the `include:` directive).
    own = {k: v for k, v in raw.items() if k != "include"}
    composed = _merge(composed, own)

    return composed


def _merge(
    left: dict[str, Any],
    right: dict[str, Any],
    _path: tuple[str, ...] = (),
) -> dict[str, Any]:
    """Recursive deep-merge per compose_policy semantics."""
    result = deepcopy(left)
    for key, rval in right.items():
        path = _path + (key,)
        if key in result:
            lval = result[key]
            if isinstance(lval, dict) and isinstance(rval, dict):
                result[key] = _merge(lval, rval, path)
            elif (
                isinstance(lval, list)
                and isinstance(rval, list)
                and _is_union_list(path, key)
            ):
                result[key] = _union_list(lval, rval, key)
            else:
                result[key] = deepcopy(rval)
        else:
            result[key] = deepcopy(rval)
    return result


def _is_union_list(path: tuple[str, ...], key: str) -> bool:
    """Return True if the list at this path should be unioned, not replaced."""
    if key in _UNION_LIST_KEYS:
        return True
    if path in _UNION_LIST_KEYS:
        return True
    return False


def _union_list(left: list[Any], right: list[Any], key: str) -> list[Any]:
    """Union two lists, deduping by `name` for ``policies:``, else by equality."""
    if key == "policies":
        # Dedupe by `name` — right-side wins for same-named policy.
        by_name: dict[str, Any] = {}
        order: list[str] = []
        for item in left + right:
            if not isinstance(item, dict) or "name" not in item:
                # Unnamed entry — append as-is.
                continue
            pname = item["name"]
            if pname not in by_name:
                order.append(pname)
            by_name[pname] = item
        unnamed = [
            x for x in left + right
            if not (isinstance(x, dict) and "name" in x)
        ]
        return [by_name[n] for n in order] + unnamed
    # Generic union: preserve order, dedupe by equality.
    seen: list[Any] = []
    for item in left + right:
        if item not in seen:
            seen.append(item)
    return seen
