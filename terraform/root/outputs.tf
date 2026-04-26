# Operator-facing outputs.
#
# Source-of-truth contract: specs/001-hardened-nemoclaw-deploy/data-model.md §2.
#
# The values are wired from the modules in main.tf. start_command is
# filled by Phase 5 (US3) when the auto-shutdown schedule lands; at
# US1 it returns a printable `az vm start ...` string already.

output "vm_tailnet_hostname" {
  value       = module.vm.tailnet_hostname_hint
  description = "Hint at the Tailscale-side hostname the VM advertises. The exact tailnet suffix (e.g. tail-scale.ts.net or your-org.ts.net) is operator-specific and substituted at use time."
}

output "vm_resource_id" {
  value       = module.vm.id
  description = "Full Azure resource ID of the VM — used for `az vm` commands."
}

output "vm_name" {
  value       = module.vm.name
  description = "VM resource name (suffix-uniqueified)."
}

output "vm_computer_name" {
  value       = module.vm.computer_name
  description = "Linux hostname (also Tailscale --hostname). What `tailscale ping <hostname>` targets."
}

output "resource_group_name" {
  value       = data.azurerm_resource_group.main.name
  description = "Resource group containing the deployment."
}

output "key_vault_uri" {
  value       = module.keyvault.uri
  description = "Key Vault URI — where the operator pre-stages the Foundry API key + Tailscale auth key."
}

output "key_vault_name" {
  value       = module.keyvault.name
  description = "Key Vault name (suffix-uniqueified)."
}

output "log_analytics_workspace_id" {
  value       = module.log_analytics.id
  description = "Log Analytics workspace resource ID — for ad-hoc KQL queries on KV audit + NSG flow logs."
}

output "start_command" {
  value       = "az vm start --resource-group ${data.azurerm_resource_group.main.name} --name ${module.vm.name}"
  description = "Copy/pasteable `az vm start ...` invocation for waking the VM after auto-shutdown."
}
