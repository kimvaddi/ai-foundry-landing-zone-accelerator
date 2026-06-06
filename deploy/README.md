# Deploy to Azure — published artifacts

This folder holds the artifacts the **Deploy to Azure** button consumes.

| File | Size | Purpose |
|---|---|---|
| [`azuredeploy.json`](azuredeploy.json) | ~22 KB | **Thin wrapper.** What the Portal deeplink fetches. Defines all 39 input parameters (so `createUiDefinition.json`'s outputs map cleanly), then issues a single sub-scope nested deployment that fetches `azuredeploy-full.json` server-side via ARM `templateLink`. |
| [`azuredeploy-full.json`](azuredeploy-full.json) | ~1.7 MB | **The real template.** Compiled output of [`../infra/bicep/main.bicep`](../infra/bicep/main.bicep). Subscription-scope. ARM fetches this server-side after the wrapper deployment is submitted, so the Portal's deeplink size limit doesn't apply. |
| [`createUiDefinition.json`](createUiDefinition.json) | ~32 KB | Custom Portal wizard with a blueprint picker, conditional hub / compute / APIM tabs, and per-blueprint defaults. |

### Why the wrapper?

The Azure Portal's `#create/Microsoft.Template/uri/...` deeplink browser-side fetch is **unreliable for templates above ~1 MB**, even though the documented ARM hard limit is 4 MB. Symptom: the Portal shows `"There was an error downloading the template from URI '...'. Ensure that the template is publicly accessible and that the publisher has enabled CORS policy on the endpoint."` even when the URL is publicly reachable with permissive CORS (`Access-Control-Allow-Origin: *`).

Pattern (industry-standard linked-template indirection):

1. User clicks **Deploy to Azure** → Portal fetches the small `azuredeploy.json` wrapper (22 KB ✓ well under any limit).
2. Portal renders `createUiDefinition.json` → user picks blueprint, fills hub IDs, etc.
3. User clicks **Create** → Portal submits the wrapper deployment with the user's parameter values.
4. ARM (server-side) processes the wrapper, sees one `Microsoft.Resources/deployments` resource, fetches `azuredeploy-full.json` via `templateLink.uri` (server-to-server fetch, no Portal involvement, no 1 MB limit), and runs the full landing-zone deployment as a nested sub-scope deployment.
5. The wrapper passes through all 31 outputs from the inner template (validation messages, foundry endpoint, workspace IDs, etc.) so the user sees them in the deployment summary.

## Button URL pattern

```
https://portal.azure.com/#create/Microsoft.Template/uri/<TEMPLATE>/createUIDefinitionUri/<UI>
```

Where `<TEMPLATE>` and `<UI>` are the **URL-encoded** raw URLs of `azuredeploy.json` (the wrapper) and `createUiDefinition.json`. The buttons in the project README use the pre-encoded form. `azuredeploy-full.json` is **not** referenced from the URL — only from inside the wrapper.

## Refreshing the templates

Whenever `infra/bicep/main.bicep` (or any module it pulls in) changes, regenerate both files:

```powershell
# 1. Recompile Bicep to the full ARM
az bicep build --file infra/bicep/main.bicep

# 2. Overwrite the full template
Copy-Item infra/bicep/main.json deploy/azuredeploy-full.json -Force

# 3. Regenerate the thin wrapper (preserves parameter defs + adds output passthroughs)
./scripts/refresh-deploy-wrapper.ps1   # see script below
```

The `infra/bicep/main.json` itself is gitignored as a transient build output; the curated copy under `deploy/azuredeploy-full.json` is the published artifact.

> **Note:** If you add/remove/rename parameters in `main.bicep`, you must also update the corresponding form fields and output mappings in `createUiDefinition.json` by hand — the schema is curated, not generated.

## Validating `createUiDefinition.json`

Use the [Create UI Definition sandbox](https://portal.azure.com/?feature.customportal=false#blade/Microsoft_Azure_CreateUIDef/SandboxBlade):

1. Open the sandbox, paste the contents of `createUiDefinition.json`, click **Preview**.
2. Walk through every tab; confirm conditional visibility on the Hub, Compute, APIM, and Notifications steps.
3. On the final step, expand **View outputs** to verify the `components` object and `existingPrivateDnsZones` map are well-formed.

## Validating the wrapper (optional)

After refreshing, you can dry-run the wrapper against your subscription **without deploying anything**:

```powershell
az deployment sub validate `
  --location eastus2 `
  --template-file deploy/azuredeploy.json `
  --parameters workload=klzfin env=dev
```

If the template URI in the wrapper is reachable, this returns `provisioningState: Succeeded`. If you see `LinkedAuthorizationFailed` or `InvalidTemplate`, double-check the raw URL in the wrapper's `templateLink.uri`.

