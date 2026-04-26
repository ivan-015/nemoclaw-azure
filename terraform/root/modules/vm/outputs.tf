# vm module — outputs.

output "id" {
  value       = azurerm_linux_virtual_machine.main.id
  description = "VM resource ID — feeds the start_command output and `az vm` calls in scripts/verify.sh."
}

output "name" {
  value       = azurerm_linux_virtual_machine.main.name
  description = "VM resource name (vm-nemoclaw-<suffix>)."
}

output "computer_name" {
  value       = azurerm_linux_virtual_machine.main.computer_name
  description = "Linux hostname (also the Tailscale --hostname). Operator's `tailscale ping <hostname>` lands here."
}

output "private_ip_address" {
  value       = azurerm_network_interface.main.private_ip_address
  description = "Private IP from the vm subnet. Surfaced for diagnostics; not used as an access path (Tailscale is the only reachable surface)."
}

output "tailnet_hostname_hint" {
  value       = "${azurerm_linux_virtual_machine.main.computer_name}.<your-tailnet>.ts.net"
  description = "Hint for the operator at apply time. The exact tailnet suffix is operator-specific (e.g. tail-scale.ts.net or your-org.ts.net) and isn't known to Terraform — the operator substitutes their tailnet when they `tailscale ping`."
}
