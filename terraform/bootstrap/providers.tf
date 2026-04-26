# Terraform & provider configuration for the bootstrap stage.
# Bootstrap runs ONCE per subscription with LOCAL state to provision
# the Azure Storage backend that all subsequent applies will use.
# After bootstrap completes, terraform/root/providers.tf consumes the
# outputs of this stage.
#
# See terraform/bootstrap/README.md for the chicken-and-egg explanation
# and the recovery path if the local state file is lost.

terraform {
  required_version = ">= 1.6"

  required_providers {
    # azurerm is exact-pinned per constitution Principle V ("exact pin
    # for security-critical providers"). The provider controls every
    # Azure resource the deploy creates; that makes it security-critical
    # in scope. Bump deliberately, with a diff and a Constitution
    # affirmation in the PR description.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.70.0"
    }

    # random is routine; ~> for patch flexibility is fine.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
