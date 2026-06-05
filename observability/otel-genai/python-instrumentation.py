"""
otel-genai/python-instrumentation.py

Minimal reference for instrumenting a Python agent runtime with OTel GenAI
semantic conventions so spans land in Application Insights with the right
dimensions for the Agent Performance workbook.

Conventions used:
- gen_ai.system        = "azure-openai"
- gen_ai.request.model
- gen_ai.usage.input_tokens / output_tokens
- gen_ai.project       (custom, picked up by the workbook)
- span name "tool.fabric.<op>" / "tool.search.<op>" so the Fabric panel finds them

Env vars required:
  APPLICATIONINSIGHTS_CONNECTION_STRING
  PROJECT_NAME  (e.g. "knowledge-search")
  AZURE_OPENAI_ENDPOINT
"""

import os
from typing import Any, Dict

from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

PROJECT = os.environ.get("PROJECT_NAME", "unknown")

# 1) Wire up App Insights exporter. Connection string from APPLICATIONINSIGHTS_CONNECTION_STRING.
configure_azure_monitor(
    resource_attributes={
        "service.name": f"foundry-agent-{PROJECT}",
        "gen_ai.project": PROJECT,
        "gen_ai.system": "azure-openai",
    },
)
tracer = trace.get_tracer(__name__)


# ---------- Tool: Fabric query (THE the customer KPI) -----------------------------
def fabric_query(sql: str) -> Dict[str, Any]:
    with tracer.start_as_current_span("tool.fabric.query") as span:
        span.set_attribute("gen_ai.project", PROJECT)
        span.set_attribute("db.system", "fabric")
        span.set_attribute("db.statement", sql[:200])
        try:
            # ... real Fabric REST / SQL endpoint call here ...
            rows = []
            span.set_attribute("db.rows_returned", len(rows))
            return {"rows": rows}
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise


# ---------- Tool: AI Search query ----------------------------------------
def search_query(q: str, top: int = 5) -> Dict[str, Any]:
    with tracer.start_as_current_span("tool.search.query") as span:
        span.set_attribute("gen_ai.project", PROJECT)
        span.set_attribute("search.query", q[:200])
        span.set_attribute("search.top_k", top)
        # ... real Search REST call ...
        return {"hits": []}


# ---------- Model completion --------------------------------------------
def chat_completion(messages: list, model: str = "gpt-4o-mini") -> Dict[str, Any]:
    with tracer.start_as_current_span("gen_ai.completion") as span:
        span.set_attribute("gen_ai.system", "azure-openai")
        span.set_attribute("gen_ai.request.model", model)
        span.set_attribute("gen_ai.project", PROJECT)
        # ... real openai.ChatCompletion.create(...) here ...
        usage = {"prompt_tokens": 0, "completion_tokens": 0}
        span.set_attribute("gen_ai.usage.input_tokens", usage["prompt_tokens"])
        span.set_attribute("gen_ai.usage.output_tokens", usage["completion_tokens"])
        return {"content": "(stub)", "usage": usage}


if __name__ == "__main__":
    # Tiny end-to-end demo
    with tracer.start_as_current_span("agent.run") as span:
        span.set_attribute("gen_ai.project", PROJECT)
        fabric_query("SELECT TOP 10 * FROM dim_part")
        search_query("compressor seal kit")
        chat_completion([{"role": "user", "content": "list 5 compatible parts"}])
