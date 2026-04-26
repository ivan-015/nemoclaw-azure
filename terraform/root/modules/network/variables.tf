# network module — input contract.
#
# Owns: VNet, subnet (with Microsoft.KeyVault service endpoint), NSG
# (zero ingress + fail-closed egress allowlist), NSG association,
# NSG flow logs storage account + diagnostic, Network Watcher Flow Log.

variable "resource_group_name" {
  type        = string
  description = "Resource group that owns the VNet/NSG/flow-logs SA."
}

variable "location" {
  type        = string
  description = "Azure region. Used for service-tag suffixing on outbound NSG rules (e.g. AzureKeyVault.<region>) and for the regional Network Watcher lookup."
}

variable "name_suffix" {
  type        = string
  description = "Stable 4-char deploy suffix from local.suffix — appended to globally-unique resource names (the flow-logs storage account)."
}

variable "tags" {
  type        = map(string)
  description = "Merged mandatory + operator tags from local.tags."
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Workspace ID for NSG flow log analytics. Passed in from the parent so the network module doesn't take a dependency on the log-analytics module's resource shape."
}

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.42.0.0/24"]
  description = "VNet CIDR. Default 10.42.0.0/24 is plenty for v1's one VM. Override only if it collides with the operator's tailnet or another peered network."
}

variable "vm_subnet_address_prefix" {
  type        = string
  default     = "10.42.0.0/27"
  description = "Subnet CIDR for the VM. /27 = 32 addresses (27 usable after Azure reservations) — far more than v1 needs."
}
