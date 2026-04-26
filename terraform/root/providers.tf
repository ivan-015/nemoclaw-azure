# Terraform & provider configuration for the main (root) stage.
#
# Backend config is supplied at `terraform init -backend-config=...`
# time using the outputs of the bootstrap stage. See quickstart.md §4
# for the exact `terraform init` command.

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

    # tls is used in modules/vm/main.tf to satisfy the provider's
    # API constraint that disable_password_authentication=true must
    # be paired with an admin_ssh_key. We generate an ED25519 key
    # whose private half stays only in Terraform state and whose
    # public half can never be reached (no public IP, NSG denies
    # all inbound). Tailscale SSH is the actual access vector.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend keys are intentionally left blank here. Supply via:
  #   terraform init \
  #     -backend-config="storage_account_name=<from bootstrap>" \
  #     -backend-config="container_name=<from bootstrap>" \
  #     -backend-config="resource_group_name=<from bootstrap>" \
  #     -backend-config="key=root.tfstate" \
  #     -backend-config="use_azuread_auth=true"
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # Same rationale as bootstrap/providers.tf — every storage account
  # this stage creates (NSG flow logs SA, etc.) will have shared
  # keys disabled, so the provider must use AAD for data-plane
  # operations.
  storage_use_azuread = true

  features {
    # Key Vault uses purge protection (constitution Security Constraints).
    # We do NOT auto-purge soft-deleted vaults on destroy — the operator
    # must wait out the soft-delete window or use a fresh per-deploy name
    # (see research R7 + spec FR-026).
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = false
    }

    virtual_machine {
      delete_os_disk_on_deletion     = true
      skip_shutdown_and_force_delete = false
      # graceful_shutdown removed: deprecated in azurerm v4, removed
      # in v5. Default behavior is unchanged (graceful shutdown when
      # the VM is asked to deallocate).
    }
  }
}
