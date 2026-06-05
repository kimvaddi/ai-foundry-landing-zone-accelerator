# KLZ OTel Collector (Phase B.2)

End-to-end OpenTelemetry pipeline for KLZ agent runtimes.

## Architecture

```
agent (python)                Container App                Azure Monitor
+--------------+   OTLP gRPC  +-----------------+   AI    +-----------+
| Instrumented |  ─────────▶  | otel-collector  | ──────▶ | App Insights |
| via          |  :4317       | (this module)   |          +-----------+
| python-      |              +-----------------+                │
| instrumentation.py |                │                          ▼
+--------------+                       │                Custom logs / KQL
                                       │
                                       └────▶ (optional)
                                              secondary OTLP backend
                                              via KLZ_SECONDARY_OTLP_ENDPOINT
```

## Files

| File | Purpose |
|------|---------|
| `infra/bicep/modules/observability/otel-collector.bicep` | Container App definition (internal-only ingress, system MI, OTLP gRPC :4317 + HTTP :4318 + health :13133). |
| `observability/otel-genai/python-instrumentation.py` | Reference instrumentation wired in Phase A.5. Set `OTEL_EXPORTER_OTLP_ENDPOINT` to the internal FQDN output by this module. |

## Wiring into main.bicep (when ready)

Currently the module is shipped as a standalone scaffold to keep the
deployed footprint small. To wire it in, add to `infra/bicep/main.bicep`:

```bicep
module otelCollector 'modules/observability/otel-collector.bicep' = if (mode == 'full' && deployOtelCollector) {
  scope: rgPlatform
  name: 'otel-${env}'
  params: {
    name: 'ca-otel-${nameSuffix}'
    location: location
    environmentId: containerAppsEnv.outputs.environmentId
    appInsightsConnectionString: appInsights.outputs.connectionString
    tags: tags
  }
}
```

You will also need a `Microsoft.App/managedEnvironments` resource — the
shared Container Apps Environment is intentionally **not** in Phase A
(no Container Apps consumers yet). Add it under
`modules/networking/container-apps-env.bicep` when you're ready to host
the collector or other agent workloads.

## Configuring agents

After deploy, the agent runtime needs three env vars:

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://<internalFqdn>:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_SERVICE_NAME=<agent-name>
```

`<internalFqdn>` is the module output `internalFqdn`. The Container App
exposes ingress only inside the Container Apps Environment's VNet, so
this URL is non-routable from outside.

## Safety notes

* **Internal ingress only.** `external: false` on the ingress means
  the collector is reachable only from co-located Container Apps.
* **System-assigned MI.** Grant `Monitoring Metrics Publisher` on any
  DCR the collector should write to (e.g. KlzAgentAudit_CL).
* **Image pinning.** The default image is the public Microsoft
  collector distribution. Pin a digest before prod:
  `mcr.microsoft.com/azuremonitor/.../collector@sha256:<digest>`.
