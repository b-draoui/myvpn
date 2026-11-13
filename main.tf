terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "***REMOVED***"
  resource_provider_registrations = "none"
}

resource "azurerm_resource_group" "vpn" {
  name     = "myvpn-tf-rg"
  location = "germanywestcentral"
}