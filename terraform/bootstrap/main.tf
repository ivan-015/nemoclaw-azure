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

# Read the AAD identity that's running `terraform apply`. Used below
# to self-grant the data-plane RBAC role the operator needs to read
# and write Terraform state.
data "azurerm_client_config" "current" {}

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
  #
  # public_network_access_enabled = true is a permitted exception
  # for the bootstrap stage: neither Private Endpoint nor a VNet
  # service endpoint can cover this account at v1 (no VNet exists
  # at bootstrap time, and PE would require its own private DNS
  # zone + bridge infra to reach from a laptop). The constitution's
  # clause "where Private Endpoint or service endpoint coverage
  # exists" deliberately excludes this case.
  #
  # We compensate with four independent layers:
  #   1. network_rules.ip_rules — only the operator's /32 reaches
  #      the data plane (see var.operator_ip_cidr).
  #   2. shared_access_key_enabled = false — no static keys exist;
  #      every data-plane op MUST authenticate via AAD.
  #   3. default_to_oauth_authentication = true — clients default
  #      to AAD instead of shared key.
  #   4. min_tls_version = TLS1_2 — no downgrade.
  # Plus data-plane RBAC scoped to the SA only (see
  # azurerm_role_assignment.operator_state_blob_writer below).
  public_network_access_enabled   = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  default_to_oauth_authentication = true

  # Single-IP allowlist on the data plane. AzureServices bypass is
  # kept on so that, e.g., Azure Monitor diagnostic-log shipping
  # (a future v2 addition) keeps working. default_action = "Deny"
  # blocks every other public IP.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = [replace(var.operator_ip_cidr, "/32", "")]
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

  # Container creation is a data-plane operation. With shared keys
  # disabled, the provider uses AAD (storage_use_azuread = true in
  # providers.tf). The role assignment below grants the operator's
  # AAD identity the data-plane permission this needs.
  depends_on = [azurerm_role_assignment.operator_state_blob_writer]
}

# Self-grant the operator's AAD identity the data-plane RBAC role.
# Subscription Owner does NOT include data-plane storage permissions
# — that's a separate role assignment scoped to the storage account.
# Without this, container creation and every subsequent state read/
# write would fail with HTTP 401 from the blob endpoint.
resource "azurerm_role_assignment" "operator_state_blob_writer" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id

  description = "Lets the operator's AAD identity read/write Terraform state via the data plane."
}
