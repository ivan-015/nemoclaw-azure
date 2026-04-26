# identity module — input contract.
#
# Owns: a user-assigned managed identity attached to the VM. The MI's
# principal_id is granted "Key Vault Secrets User" at the KV resource
# scope by the keyvault module (Principle III, narrowest viable RBAC).
# The credential handoff and cloud-init both authenticate as this MI
# via `az login --identity`.

variable "resource_group_name" {
  type        = string
  description = "Resource group for the identity."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name" {
  type        = string
  description = "Identity name (passed in from local.mi_name)."
}

variable "tags" {
  type        = map(string)
  description = "Merged mandatory + operator tags."
}
