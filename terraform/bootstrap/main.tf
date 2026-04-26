# Bootstrap stage: provisions the Azure Storage backend that
# terraform/root/ uses for remote state.
#
# Run ONCE per subscription with LOCAL state (no backend block in
# terraform/bootstrap/providers.tf). After this stage's outputs are
# captured, the operator runs `terraform init -backend-config=...`
# in terraform/root/ using those outputs.
#
# Constitution Principle V: this stage IS the documented exception
# to "MUST live in a remote backend" — the chicken-and-egg
# bootstrap of the backend itself.
#
# See README.md (in this directory) for the recovery path if the
# local state file is lost.

resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false

  # Bootstrap suffix is independent of the root-stage deploy_suffix.
  # If a redeploy needs a fresh storage account name, taint this
  # resource and re-apply.
}

resource "azurerm_resource_group" "state" {
  name     = "rg-nemoclaw-tfstate"
  location = var.location
  tags     = local.mandatory_tags
}

resource "azurerm_storage_account" "state" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Constitution Security Constraints — storage account hardening.
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  # Azure AD auth only; no SAS, no shared key. The operator's
  # `terraform init` uses `use_azuread_auth=true` to access state.
  default_to_oauth_authentication = true

  # Storage account uses Azure-AD-authenticated network rules. With
  # public access disabled we must also set the firewall rules.
  # `bypass = ["AzureServices"]` is required for managed-identity
  # access from the same region; `default_action = "Deny"` prevents
  # any other access.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  blob_properties {
    versioning_enabled = true

    # Soft-delete buys 7 days of recovery if state is accidentally
    # deleted. Cheap insurance for the most precious file in the
    # deploy.
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.mandatory_tags
}

resource "azurerm_storage_container" "state" {
  name                  = local.state_container_name
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}
