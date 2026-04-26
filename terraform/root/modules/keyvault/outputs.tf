# keyvault module — outputs.

output "id" {
  value       = azurerm_key_vault.main.id
  description = "Key Vault resource ID."
}

output "name" {
  value       = azurerm_key_vault.main.name
  description = "Key Vault name (suffix-uniqueified)."
}

output "uri" {
  value       = azurerm_key_vault.main.vault_uri
  description = "Key Vault URI (e.g. https://kv-nc-1a2b.vault.azure.net/)."
}

output "foundry_secret_name" {
  value       = azurerm_key_vault_secret.foundry_api_key.name
  description = "Name of the Foundry API key secret. Cloud-init's credential handoff fetches this name (kept stable across redeploys per kv-secret-layout.md)."
}

output "tailscale_secret_name" {
  value       = azurerm_key_vault_secret.tailscale_auth_key.name
  description = "Name of the Tailscale auth key secret. Cloud-init reads this once at first boot."
}
