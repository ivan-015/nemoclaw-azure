# network module — outputs consumed by sibling modules.

output "vnet_id" {
  value       = azurerm_virtual_network.main.id
  description = "VNet resource ID."
}

output "vnet_name" {
  value       = azurerm_virtual_network.main.name
  description = "VNet name."
}

output "vm_subnet_id" {
  value       = azurerm_subnet.vm.id
  description = "VM subnet resource ID. Consumed by the keyvault module's network_acls block (R13) and by the vm module's NIC."
}

output "vm_subnet_name" {
  value       = azurerm_subnet.vm.name
  description = "VM subnet name."
}

output "nsg_id" {
  value       = azurerm_network_security_group.vm.id
  description = "NSG resource ID — referenced by the post-apply verify.sh check 2b."
}

output "nsg_name" {
  value       = azurerm_network_security_group.vm.name
  description = "NSG name."
}

output "flowlogs_storage_account_id" {
  value       = azurerm_storage_account.flowlogs.id
  description = "Storage account holding NSG flow logs."
}
