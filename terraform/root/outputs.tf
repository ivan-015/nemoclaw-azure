# Operator-facing outputs. Surfaces are placeholders at Phase 2 — the
# real values are wired in as later phases add the modules they
# come from. Keeping the surface stable lets `terraform output -raw`
# scripts in scripts/verify.sh be written once.
#
# Source-of-truth: specs/001-hardened-nemoclaw-deploy/data-model.md §2.

output "vm_tailnet_hostname" {
  value       = null # populated in Phase 3 (US1) once the VM module is wired
  description = "Hostname the VM advertises on the tailnet (e.g. nemoclaw-3f2a.tail-scale.ts.net)."
}

output "vm_resource_id" {
  value       = null # populated in Phase 3 (US1)
  description = "Full Azure resource ID of the VM — used for `az vm` commands."
}

output "vm_name" {
  value       = null # populated in Phase 3 (US1)
  description = "VM resource name (the suffix-uniqueified name)."
}

output "resource_group_name" {
  value       = null # populated in Phase 3 (US1)
  description = "Resource group containing the deployment."
}

output "key_vault_uri" {
  value       = null # populated in Phase 3 (US1) by the keyvault module
  description = "Key Vault URI — where the operator pre-stages the Foundry API key + Tailscale auth key."
}

output "key_vault_name" {
  value       = null # populated in Phase 3 (US1) by the keyvault module
  description = "Key Vault name (suffix-uniqueified)."
}

output "log_analytics_workspace_id" {
  value       = null # populated in Phase 3 (US1) by the log-analytics module
  description = "Log Analytics workspace ID — for ad-hoc KQL queries on KV audit + NSG flow logs."
}

output "start_command" {
  value       = null # populated in Phase 5 (US3) once VM name + RG name are known
  description = "Copy/pasteable `az vm start ...` invocation for waking the VM after auto-shutdown."
}
