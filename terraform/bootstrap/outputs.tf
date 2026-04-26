# Bootstrap-stage outputs.
#
# After `terraform apply` here, the operator captures these and feeds
# them into `terraform/root/`'s `terraform init -backend-config=...`
# invocation. See README.md in this directory for the exact sequence.

output "resource_group_name" {
  value       = azurerm_resource_group.state.name
  description = "Resource group holding the Terraform state backend."
}

output "storage_account_name" {
  value       = azurerm_storage_account.state.name
  description = "Storage account holding the Terraform state container."
}

output "container_name" {
  value       = azurerm_storage_container.state.name
  description = "Blob container that holds Terraform state files."
}

# Convenience output: a copy/pasteable backend-config block. Print it
# at apply time and feed it into `terraform init -backend-config=...`
# in terraform/root/.
output "backend_config_block" {
  value       = <<-EOT
    terraform init \
      -backend-config="resource_group_name=${azurerm_resource_group.state.name}" \
      -backend-config="storage_account_name=${azurerm_storage_account.state.name}" \
      -backend-config="container_name=${azurerm_storage_container.state.name}" \
      -backend-config="key=root.tfstate" \
      -backend-config="use_azuread_auth=true"
  EOT
  description = "Copy/paste-ready `terraform init` invocation for terraform/root/."
}
