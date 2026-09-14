# principal code

# Configure the Azure provider
terraform {
  cloud {
    organization = "42-cloud-1"
    workspaces {
      name = "terraform-azure-migrate"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  # name     = "myTFResourceGroup"
  name     = var.resource_group_name
  location = "spaincentral"
}
