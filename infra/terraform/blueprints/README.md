# Blueprints (Terraform)

See ../../bicep/blueprints/README.md for the matrix and usage.

## Terraform-specific usage

```powershell
cd infra/terraform
terraform init
terraform plan  -var-file=blueprints/<name>/<name>.tfvars
terraform apply -var-file=blueprints/<name>/<name>.tfvars
```
