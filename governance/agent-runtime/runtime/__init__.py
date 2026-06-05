# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
"""KLZ agent-runtime — runtime enforcement layer.

The loader/composer (governance.agent_runtime.loader) gives a resolved
policy dict. This subpackage uses that dict at request time to:

  * pre-flight an outbound call (chargeback headers, egress allowlist,
    model allowlist, cost cap),
  * route the call through APIM,
  * post a structured audit row to KlzAgentAudit_CL via the DCE,
  * surface a decision (allow|deny|warn) + signal payload to the caller.

The KlzClient is the integration point for product teams. The
PolicyDecision dataclass + audit POSTer are also reusable standalone.
"""
# Re-export for convenience; tests import via `from runtime.klz_client import ...`
# to align with the flat sys.path layout in tests/conftest.py.
from runtime.klz_client import (  # noqa: F401
    AuditWriter,
    KlzClient,
    KlzConfig,
    PolicyDecision,
    PolicyViolation,
)

__all__ = [
    "AuditWriter",
    "KlzClient",
    "KlzConfig",
    "PolicyDecision",
    "PolicyViolation",
]
