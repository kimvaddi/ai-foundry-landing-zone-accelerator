terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.20" }
    azapi   = { source = "Azure/azapi", version = "~> 2.0" }
  }
}
