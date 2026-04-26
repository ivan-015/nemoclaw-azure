# identity module — outputs.

output "id" {
  value       = azurerm_user_assigned_identity.main.id
  description = "Resource ID of the user-assigned managed identity. Consumed by the vm module's `identity { identity_ids = [...] }` block."
}

output "principal_id" {
  value       = azurerm_user_assigned_identity.main.principal_id
  description = "AAD principal_id of the MI. Consumed by the keyvault module for the `Key Vault Secrets User` role assignment."
}

output "client_id" {
  value       = azurerm_user_assigned_identity.main.client_id
  description = "AAD client_id of the MI. Available to cloud-init via templatefile() for explicit `az login --identity --username <client_id>` if multiple identities are ever attached."
}

output "name" {
  value       = azurerm_user_assigned_identity.main.name
  description = "Identity resource name."
}
