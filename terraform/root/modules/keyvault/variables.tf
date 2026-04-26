# keyvault module — input contract.
#
# This is the most security-sensitive module in v1. It owns:
#   - the Key Vault (RBAC mode, public access OFF, purge protection ON,
#     network ACL restricting access to the vm subnet via the
#     Microsoft.KeyVault service endpoint — research R13)
#   - RBAC: VM MI gets "Key Vault Secrets User" (scope = this KV only)
#     so it can Get/List but not Set/Delete (Principle III)
#   - RBAC: operator gets "Key Vault Secrets Officer" so `az keyvault
#     secret set` works between the staged applies without a manual
#     RBAC step (still narrow — bound to this KV only)
#   - diagnostic settings (AuditEvent + AllMetrics) → Log Analytics
#     (FR-010 / SC-008 — the audit trail for the credential handoff)
#   - placeholder secrets for foundry-api-key and tailscale-auth-key
#     with lifecycle.ignore_changes on `value` so the operator's
#     `az keyvault secret set` is not reverted by subsequent applies.

variable "resource_group_name" {
  type        = string
  description = "Resource group for the vault."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name" {
  type        = string
  description = "Key Vault name (passed in from local.kv_name — suffix-uniqueified per research R7)."
}

variable "tags" {
  type        = map(string)
  description = "Merged mandatory + operator tags."
}

variable "tenant_id" {
  type        = string
  description = "AAD tenant ID. Sourced from azurerm_client_config in the parent root module to keep the keyvault module self-contained."
}

variable "vm_subnet_id" {
  type        = string
  description = "Subnet ID with the Microsoft.KeyVault service endpoint enabled. Allowed by the network ACL."
}

variable "vm_managed_identity_principal_id" {
  type        = string
  description = "Principal ID of the VM's user-assigned managed identity. Granted Key Vault Secrets User at this vault's scope."
}

variable "operator_principal_id" {
  type        = string
  description = "Principal ID of the operator's AAD user — granted Key Vault Secrets Officer so `az keyvault secret set` works between staged applies. Bound to this KV scope only (Principle III)."
}

variable "operator_ip_cidr" {
  type        = string
  description = "Operator's public IP as a /32 CIDR (e.g. 203.0.113.5/32). Added to network_acls.ip_rules so `az keyvault secret set` from the operator's laptop reaches the data plane despite public_network_access_enabled=false."

  validation {
    # `cidrhost()` errors on malformed CIDRs; `can()` traps that into
    # a plan-time error rather than an opaque Azure API rejection at
    # apply time. Same pattern as terraform/root/variables.tf.
    condition = (
      can(cidrhost(var.operator_ip_cidr, 0))
      && endswith(var.operator_ip_cidr, "/32")
      && var.operator_ip_cidr != "0.0.0.0/32"
    )
    error_message = "operator_ip_cidr must be a syntactically valid /32 single-host CIDR (e.g. 203.0.113.5/32). 0.0.0.0/32 is rejected; constitution Principle V forbids effectively-public allowlists."
  }
}

variable "log_analytics_workspace_id" {
  type        = string
  description = "Workspace resource ID for diagnostic settings (FR-010)."
}

variable "soft_delete_retention_days" {
  type        = number
  default     = 7
  description = "Soft-delete retention. Minimum allowed by Azure is 7. Combined with research R7's deploy_suffix, this lets a destroy/redeploy succeed without waiting out the retention window (spec FR-026)."

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 (Azure minimum) and 90 (Azure maximum)."
  }
}
