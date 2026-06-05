# Copyright (c) Microsoft Corporation. Licensed under the MIT License.
# =============================================================================
# KLZ FinOps Accelerator — agent runtime client
# =============================================================================
# Loads a composed KLZ policy (via governance.agent_runtime.loader), enforces
# it on every outbound call, ships the call through APIM, then writes a
# structured audit row to KlzAgentAudit_CL via the Phase B.3 DCR.
#
# Design constraints:
#   * NO hard dependency on azure-* SDKs. Auth + ingest are pluggable via
#     callables so the module is unit-testable without network/credentials.
#     A thin convenience factory wires DefaultAzureCredential + requests
#     when those packages are present.
#   * Strict separation: PolicyDecision is the only thing the enforcement
#     layer emits; the audit writer + transport know nothing about policy.
#   * Fail-closed: if a SIGSTOP/SIGKILL policy fires, no upstream call is
#     made; we still emit the audit row so the deny is traceable.
# =============================================================================
"""Runtime client that fuses policy enforcement + APIM transport + audit."""
from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from fnmatch import fnmatch
from typing import Any, Callable, Iterable, Mapping
from urllib.parse import urlparse

from loader import compose_policy  # noqa: E402  — sys.path injected by conftest

_log = logging.getLogger(__name__)

# -----------------------------------------------------------------------------
# Type aliases
# -----------------------------------------------------------------------------
TokenProvider = Callable[[], str]
"""A zero-arg callable returning a fresh OAuth2 access token."""

Transport = Callable[[str, str, Mapping[str, str], dict[str, Any]], "RawResponse"]
"""A callable (method, url, headers, body) -> RawResponse for the upstream call."""

IngestPoster = Callable[[str, Mapping[str, str], list[dict[str, Any]]], int]
"""A callable (url, headers, rows) -> http_status for DCE ingest POSTs."""


# -----------------------------------------------------------------------------
# Data shapes
# -----------------------------------------------------------------------------
@dataclass
class RawResponse:
    """Minimal upstream response shape the client needs."""
    status: int
    headers: Mapping[str, str]
    body: dict[str, Any]
    latency_ms: int = 0


@dataclass
class KlzConfig:
    """Wire-level configuration for a single KLZ runtime client.

    All endpoints are tenant-injected by deploy.ps1; agents never hand-code.
    """
    apim_gateway: str                    # e.g. https://apim-klzfin-dev-c6ej.azure-api.net
    apim_subscription_key: str | None    # optional: APIM may use Entra-only
    dce_endpoint: str                    # e.g. https://dce-klzfin-dev-c6ej.eastus2-1.ingest.monitor.azure.com
    dcr_immutable_id: str                # output of finops module (agentAuditDcrImmutableId)
    stream_name: str = "Custom-KlzAgentAudit_CL"
    apim_audience: str = "https://cognitiveservices.azure.com/.default"
    monitor_audience: str = "https://monitor.azure.com/.default"
    policy_template: str = "klz-baseline"
    agent_name: str = "unknown-agent"
    agent_version: str = "0.0.0"
    region: str = "eastus2"
    timeout_seconds: float = 60.0
    cost_estimator: Callable[[str, int, int], float] | None = None
    """Optional (model, prompt_tokens, completion_tokens) -> usd estimate."""


@dataclass
class PolicyViolation:
    """A single policy failure surfaced by enforcement."""
    policy: str
    field: str
    reason: str
    severity: str
    signal: str
    action: str                          # SIGSTOP | SIGKILL | WARN


@dataclass
class PolicyDecision:
    """Outcome of pre-flight enforcement for one outbound call."""
    decision: str                        # allow | deny | warn
    violations: list[PolicyViolation] = field(default_factory=list)
    policy_template: str = ""
    policy_version: str = ""
    correlation_id: str = ""

    @property
    def is_allowed(self) -> bool:
        return self.decision == "allow"

    @property
    def primary_violation(self) -> PolicyViolation | None:
        return self.violations[0] if self.violations else None


# -----------------------------------------------------------------------------
# Audit writer
# -----------------------------------------------------------------------------
class AuditWriter:
    """POSTs structured audit rows to a Log Analytics DCR via the DCE.

    Stateless. Pass-through for the IngestPoster callable so tests can swap
    in an in-memory recorder.
    """

    def __init__(
        self,
        config: KlzConfig,
        token_provider: TokenProvider,
        poster: IngestPoster,
    ) -> None:
        self._cfg = config
        self._token = token_provider
        self._poster = poster

    def _url(self) -> str:
        return (
            f"{self._cfg.dce_endpoint.rstrip('/')}/dataCollectionRules/"
            f"{self._cfg.dcr_immutable_id}/streams/{self._cfg.stream_name}"
            f"?api-version=2023-01-01"
        )

    def write(self, row: dict[str, Any]) -> int:
        """Post a single audit row. Returns the HTTP status code."""
        headers = {
            "Authorization": f"Bearer {self._token()}",
            "Content-Type": "application/json",
        }
        # DCE accepts an array; one row per call keeps blast-radius small.
        return self._poster(self._url(), headers, [row])


# -----------------------------------------------------------------------------
# Enforcement helpers
# -----------------------------------------------------------------------------
def _flatten_policies(composed: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Return the merged `policies:` list (composed by loader) as plain dicts."""
    policies = composed.get("policies") or []
    return [dict(p) for p in policies if isinstance(p, Mapping)]


def _matches_any(host: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch(host, p) for p in patterns)


def _check_required_headers(
    policy: Mapping[str, Any],
    headers: Mapping[str, str],
) -> PolicyViolation | None:
    required = policy.get("require_headers") or []
    missing = [h for h in required if h not in {k.lower() for k in headers.keys()}]
    if not missing:
        return None
    return PolicyViolation(
        policy=policy.get("name", "unnamed"),
        field=",".join(missing),
        reason=f"required header(s) missing: {', '.join(missing)}",
        severity=policy.get("severity", "medium"),
        signal="chargeback_header_missing",
        action=policy.get("action", "SIGSTOP"),
    )


def _check_egress(
    policy: Mapping[str, Any],
    url: str,
) -> PolicyViolation | None:
    host = urlparse(url).hostname or ""
    allow_rules = policy.get("allow") or []
    deny_rules = policy.get("deny") or []

    allowed_hosts: list[str] = []
    for rule in allow_rules:
        if rule.get("action") == "http_request":
            allowed_hosts.extend(rule.get("domains") or [])

    if allowed_hosts and not _matches_any(host, allowed_hosts):
        # not in allowlist -> evaluate deny rules
        for rule in deny_rules:
            if rule.get("action") == "http_request":
                domains = rule.get("domains") or []
                if "*" in domains or _matches_any(host, domains):
                    return PolicyViolation(
                        policy=policy.get("name", "unnamed"),
                        field="url.host",
                        reason=f"host '{host}' is not in egress allowlist",
                        severity=policy.get("severity", "critical"),
                        signal="shadow_ai_egress",
                        action=policy.get("action", "SIGKILL"),
                    )
    return None


def _check_model_allowlist(
    policy: Mapping[str, Any],
    model: str | None,
) -> PolicyViolation | None:
    allowlist = policy.get("model_allowlist") or policy.get("allowed_models")
    if not allowlist or model is None:
        return None
    if model in allowlist:
        return None
    return PolicyViolation(
        policy=policy.get("name", "unnamed"),
        field="model",
        reason=f"model '{model}' is not in allowed set",
        severity=policy.get("severity", "high"),
        signal="model_not_allowed",
        action=policy.get("action", "SIGSTOP"),
    )


def _decide(violations: list[PolicyViolation]) -> str:
    if not violations:
        return "allow"
    for v in violations:
        if v.action in ("SIGSTOP", "SIGKILL"):
            return "deny"
    return "warn"


# -----------------------------------------------------------------------------
# Client
# -----------------------------------------------------------------------------
class KlzClient:
    """Policy-enforced wrapper around an upstream AI call + audit.

    Typical usage::

        client = KlzClient.from_env(KlzConfig(...))
        decision, response = client.invoke(
            method="POST",
            path="/openai/deployments/gpt-4o-mini/chat/completions",
            headers={
                "x-project-name": "demo",
                "x-use-case": "test",
                "x-cost-center": "CC-1000",
            },
            body={"messages": [{"role": "user", "content": "hi"}]},
            model="gpt-4o-mini",
        )
        if not decision.is_allowed:
            raise RuntimeError(decision.primary_violation.reason)
    """

    def __init__(
        self,
        config: KlzConfig,
        transport: Transport,
        apim_token_provider: TokenProvider,
        audit_writer: AuditWriter,
        policy: Mapping[str, Any] | None = None,
    ) -> None:
        self._cfg = config
        self._transport = transport
        self._apim_token = apim_token_provider
        self._audit = audit_writer
        self._policy = dict(policy) if policy is not None else compose_policy(config.policy_template)
        self._policies = _flatten_policies(self._policy)
        self._policy_version = str(
            self._policy.get("kernel", {}).get("version", "unknown")
        )

    # ---- pre-flight enforcement ----------------------------------------
    def preflight(
        self,
        url: str,
        headers: Mapping[str, str],
        model: str | None,
    ) -> PolicyDecision:
        """Run all policies that gate this outbound call. No network I/O."""
        correlation_id = headers.get("x-correlation-id") or str(uuid.uuid4())
        violations: list[PolicyViolation] = []
        for p in self._policies:
            if "require_headers" in p:
                v = _check_required_headers(p, headers)
                if v:
                    violations.append(v)
                    continue
            if "allow" in p or "deny" in p:
                v = _check_egress(p, url)
                if v:
                    violations.append(v)
                    continue
            if "model_allowlist" in p or "allowed_models" in p:
                v = _check_model_allowlist(p, model)
                if v:
                    violations.append(v)
        return PolicyDecision(
            decision=_decide(violations),
            violations=violations,
            policy_template=self._cfg.policy_template,
            policy_version=self._policy_version,
            correlation_id=correlation_id,
        )

    # ---- the main API ---------------------------------------------------
    def invoke(
        self,
        *,
        method: str,
        path: str,
        headers: Mapping[str, str],
        body: dict[str, Any],
        model: str | None = None,
    ) -> tuple[PolicyDecision, RawResponse | None]:
        """Run preflight, then (if allowed) make the upstream call, then audit.

        Returns (decision, response). response is None when decision==deny.
        """
        url = f"{self._cfg.apim_gateway.rstrip('/')}/{path.lstrip('/')}"
        full_headers: dict[str, str] = {k: v for k, v in headers.items()}
        if self._cfg.apim_subscription_key:
            full_headers.setdefault("Ocp-Apim-Subscription-Key", self._cfg.apim_subscription_key)
        full_headers.setdefault("Authorization", f"Bearer {self._apim_token()}")
        full_headers.setdefault("Content-Type", "application/json")

        decision = self.preflight(url, full_headers, model)

        response: RawResponse | None = None
        if decision.is_allowed:
            t0 = time.perf_counter()
            try:
                response = self._transport(method, url, full_headers, body)
                response.latency_ms = int((time.perf_counter() - t0) * 1000)
            except Exception as exc:  # pragma: no cover — network failure path
                _log.exception("upstream call failed", exc_info=exc)
                response = RawResponse(status=599, headers={}, body={"error": str(exc)})
                response.latency_ms = int((time.perf_counter() - t0) * 1000)

        # always audit (allow + deny + warn) — this is the only place the row
        # is written, so a failed call still produces a trail.
        self._write_audit(decision, full_headers, model, response)
        return decision, response

    # ---- audit ----------------------------------------------------------
    def _estimate_cost(
        self,
        model: str | None,
        prompt: int,
        completion: int,
    ) -> float:
        if model and self._cfg.cost_estimator:
            try:
                return float(self._cfg.cost_estimator(model, prompt, completion))
            except Exception:  # pragma: no cover — estimator is user code
                return 0.0
        return 0.0

    def _write_audit(
        self,
        decision: PolicyDecision,
        headers: Mapping[str, str],
        model: str | None,
        response: RawResponse | None,
    ) -> None:
        primary = decision.primary_violation
        usage = (response.body.get("usage") if response and isinstance(response.body, Mapping) else None) or {}
        prompt_tokens = int(usage.get("prompt_tokens") or 0)
        completion_tokens = int(usage.get("completion_tokens") or 0)
        total_tokens = int(usage.get("total_tokens") or (prompt_tokens + completion_tokens))
        cost = self._estimate_cost(model, prompt_tokens, completion_tokens)

        row = {
            "TimeGenerated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
            "CorrelationId": decision.correlation_id,
            "ProjectName": headers.get("x-project-name", ""),
            "UseCase": headers.get("x-use-case", ""),
            "CostCenter": headers.get("x-cost-center", ""),
            "SubscriptionId": headers.get("x-subscription-id", ""),
            "PolicyTemplate": decision.policy_template,
            "PolicyVersion": decision.policy_version,
            "Decision": decision.decision,
            "Signal": primary.signal if primary else "",
            "ViolatedPolicy": primary.policy if primary else "",
            "ViolatedField": primary.field if primary else "",
            "Reason": primary.reason if primary else "",
            "Model": model or "",
            "OperationId": headers.get("x-operation-id", ""),
            "PromptTokens": prompt_tokens,
            "CompletionTokens": completion_tokens,
            "TotalTokens": total_tokens,
            "EstimatedCostUsd": round(cost, 6),
            "LatencyMs": response.latency_ms if response else 0,
            "HttpStatus": response.status if response else 0,
            "GatewayHost": urlparse(self._cfg.apim_gateway).hostname or "",
            "Region": self._cfg.region,
            "AgentName": self._cfg.agent_name,
            "AgentVersion": self._cfg.agent_version,
            "AuditPayload": json.dumps(
                {"violations": [asdict(v) for v in decision.violations]},
                separators=(",", ":"),
            ),
        }
        try:
            self._audit.write(row)
        except Exception as exc:  # pragma: no cover — audit failures don't break call
            _log.warning("audit write failed: %s", exc)

    # ---- convenience factory -------------------------------------------
    @classmethod
    def from_env(
        cls,
        config: KlzConfig,
        *,
        policy: Mapping[str, Any] | None = None,
    ) -> "KlzClient":
        """Wire the client against azure-identity + requests (must be installed)."""
        try:
            from azure.identity import DefaultAzureCredential  # type: ignore
            import requests  # type: ignore
        except ImportError as exc:  # pragma: no cover — runtime-only deps
            raise RuntimeError(
                "KlzClient.from_env() requires `azure-identity` and `requests`. "
                "Install governance/agent-runtime extras or pass explicit transport."
            ) from exc

        cred = DefaultAzureCredential()

        def apim_token() -> str:
            return cred.get_token(config.apim_audience).token

        def monitor_token() -> str:
            return cred.get_token(config.monitor_audience).token

        def transport(method: str, url: str, headers: Mapping[str, str], body: dict[str, Any]) -> RawResponse:
            r = requests.request(
                method,
                url,
                headers=dict(headers),
                json=body,
                timeout=config.timeout_seconds,
            )
            try:
                payload = r.json()
            except ValueError:
                payload = {"text": r.text}
            return RawResponse(status=r.status_code, headers=dict(r.headers), body=payload)

        def poster(url: str, headers: Mapping[str, str], rows: list[dict[str, Any]]) -> int:
            r = requests.post(url, headers=dict(headers), json=rows, timeout=config.timeout_seconds)
            return r.status_code

        writer = AuditWriter(config, monitor_token, poster)
        return cls(
            config=config,
            transport=transport,
            apim_token_provider=apim_token,
            audit_writer=writer,
            policy=policy,
        )
