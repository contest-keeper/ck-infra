terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.29"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # The state lives in the Azure Storage account made once with bootstrap.sh.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  # Resource providers are registered once by bootstrap.sh.
  resource_provider_registrations = "none"
  # Storage is reached with the deploy identity, not an account key (the site account has keys off).
  storage_use_azuread = true
}

# The token comes from CLOUDFLARE_API_TOKEN (the deploy workflow sets it from a GitHub secret). Without a zone
# id and a public hostname nothing is made in Cloudflare, and then the provider is never used.
provider "cloudflare" {}
