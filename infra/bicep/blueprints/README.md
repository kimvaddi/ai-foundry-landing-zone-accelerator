# Blueprints

Pre-configured deploy "shapes" for klz-accelerator-finops. Each blueprint is a
parameter overlay that drives the engine (Bicep `main.bicep` or Terraform
`infra/terraform/main.tf`) with a coherent set of toggles — saving you from
authoring a full `*.bicepparam` / `*.tfvars` per environment.

## Matrix

| Blueprint                 | networkMode               | FW       | DNS zones      | Bastion/Jump | APIM            | AppGW | CAE | Foundry agent svc |
|---------------------------|---------------------------|----------|----------------|--------------|-----------------|-------|-----|-------------------|
| `smoke`                   | standalone (skipped PEs)  | –        | –              | –            | –               | –     | –   | –                 |
| `poc-standalone-spoke`    | standalone                | –        | module-owned   | off          | off             | off   | off | off               |
| `poc-hub-connected`       | hub-connected (BYO hub)   | BYO      | hub-referenced | off          | off             | off   | on  | on                |
| `prod-standalone-with-fw` | standalone-with-firewall* | module   | module-owned   | on           | StandardV2 int. | on    | on  | on                |
| `prod-hub-connected`      | hub-connected (BYO hub)   | BYO      | hub-referenced | on           | StandardV2 int. | on    | on  | on                |

*`standalone-with-firewall` is currently DEFERRED in the engine. The
blueprint will become deployable once the two-pass firewall+UDR deploy
lands.

## Usage

### Bicep

```powershell
az deployment sub create `
  --subscription <subscription-id> `
  --location eastus2 `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/blueprints/poc-standalone-spoke/poc-standalone-spoke.bicepparam
```

### Terraform

```powershell
cd infra/terraform
terraform init
terraform plan  -var-file=blueprints/poc-standalone-spoke/poc-standalone-spoke.tfvars
terraform apply -var-file=blueprints/poc-standalone-spoke/poc-standalone-spoke.tfvars
```

## What needs to be filled in for hub-connected blueprints

The `poc-hub-connected` and `prod-hub-connected` blueprints contain `REPLACE`
placeholders for:

- `hub_vnet_resource_id` / `hubVnetResourceId` — full ARM ID of the hub VNet
- `hub_firewall_private_ip` / `hubFirewallPrivateIp` — internal IP of the hub firewall
- `existing_private_dns_zones` / `existingPrivateDnsZones` — map of friendly name → existing zone ID

After filling those in, copy the blueprint into your own `tfvars` /
`bicepparam` file (don't commit a customer-specific file back to the
public repo).

## Compute credentials (Bastion + Jump + Build)

Blueprints that enable `jumpvm` and/or `buildvm` need credentials supplied at
deploy time — they are **NOT** stored in the blueprint files. Pass them via
`-var` (Terraform) or `--parameters` (Bicep):

```powershell
# Terraform
$env:KLZ_JUMPVM_PWD     = '<strong-Windows-password-12+chars>'
$env:KLZ_BUILDVM_SSHKEY = (Get-Content ~/.ssh/id_ed25519.pub -Raw).Trim()
terraform apply -var-file=blueprints/prod-hub-connected/prod-hub-connected.tfvars `
                -var "jumpvm_admin_password=$env:KLZ_JUMPVM_PWD" `
                -var "buildvm_ssh_public_key=$env:KLZ_BUILDVM_SSHKEY"

# Bicep
az deployment sub create `
  --subscription <sub-id> --location eastus2 `
  --template-file infra/bicep/main.bicep `
  --parameters infra/bicep/blueprints/prod-hub-connected/prod-hub-connected.bicepparam `
  --parameters jumpvmAdminPassword=$env:KLZ_JUMPVM_PWD `
  --parameters buildvmSshPublicKey=$env:KLZ_BUILDVM_SSHKEY
```

## QA status (last validated)

All 5 Bicep blueprints `az bicep build-params` clean.
All 5 Terraform blueprints + `full.tfvars` + `stage-b-toggles.tfvars` + `enterprise-hub-connected.sample.tfvars` reach `terraform plan` with **0 errors**:

| File | Resources to add |
|---|---|
| `parameters/full.tfvars` | 75 |
| `parameters/stage-b-toggles.tfvars` | 105 |
| `parameters/enterprise-hub-connected.sample.tfvars` | 82 |
| `blueprints/smoke/smoke.tfvars` | 71 |
| `blueprints/poc-standalone-spoke/poc-standalone-spoke.tfvars` | 71 |
| `blueprints/poc-hub-connected/poc-hub-connected.tfvars` | 55 |
| `blueprints/prod-standalone-with-fw/prod-standalone-with-fw.tfvars` | 110 |
| `blueprints/prod-hub-connected/prod-hub-connected.tfvars` | 85 |
