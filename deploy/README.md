# Deploy to Azure — published artifacts

This folder holds the artifacts the **Deploy to Azure** button consumes.

| File | Purpose |
|---|---|
| [`azuredeploy.json`](azuredeploy.json) | ARM template compiled from [`../infra/bicep/main.bicep`](../infra/bicep/main.bicep). Subscription-scope. |
| [`createUiDefinition.json`](createUiDefinition.json) | Custom Portal wizard with a blueprint picker, conditional hub / compute / APIM tabs, and per-blueprint defaults. |

## Button URL pattern

```
https://portal.azure.com/#create/Microsoft.Template/uri/<TEMPLATE>/createUIDefinitionUri/<UI>
```

Where `<TEMPLATE>` and `<UI>` are the **URL-encoded** raw URLs of the two JSON files. The buttons in the project README use the pre-encoded form.

## Refreshing `azuredeploy.json`

Whenever `infra/bicep/main.bicep` (or any module it pulls in) changes, regenerate:

```powershell
az bicep build --file infra/bicep/main.bicep
Copy-Item infra/bicep/main.json deploy/azuredeploy.json -Force
```

The `infra/bicep/main.json` itself is gitignored as a transient build output; the curated copy under `deploy/` is the published artifact.

## Validating `createUiDefinition.json`

Use the [Create UI Definition sandbox](https://portal.azure.com/?feature.customportal=false#blade/Microsoft_Azure_CreateUIDef/SandboxBlade):

1. Open the sandbox, paste the contents of `createUiDefinition.json`, click **Preview**.
2. Walk through every tab; confirm conditional visibility on the Hub, Compute, APIM, and Notifications steps.
3. On the final step, expand **View outputs** to verify the `components` object and `existingPrivateDnsZones` map are well-formed.
