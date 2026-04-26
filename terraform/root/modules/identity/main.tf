# User-assigned managed identity for the NemoClaw VM.
#
# This identity:
#   - is attached to the VM (set in terraform/root/modules/vm/main.tf)
#   - is granted `Key Vault Secrets User` on the KV resource scope only
#     (Principle III — narrowest possible RBAC). The role permits
#     `Get` and `List` on secrets; no Set, no Delete.
#   - authenticates the VM at the IMDS endpoint, so on-VM scripts use
#     `az login --identity` and the credential handoff fetches the
#     Foundry API key without any static credential ever touching the
#     filesystem.

resource "azurerm_user_assigned_identity" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}
