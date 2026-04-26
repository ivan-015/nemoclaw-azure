# log-analytics module — input contract.
#
# Owns: one Log Analytics workspace. Consumers at v1:
#   - keyvault module → diagnostic settings (AuditEvent + AllMetrics)
#   - network module  → NSG flow logs Traffic Analytics
#   - vm module       → boot diagnostics if/when AMA agent is added (v2)
#
# Constitution Security Constraints: retention >= 30 days. Set to 30
# (the minimum) at v1 — bumping retention is cheap when needed but
# defaulting to the floor keeps cost predictable per spec SC-005.

variable "resource_group_name" {
  type        = string
  description = "Resource group for the workspace."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "name_suffix" {
  type        = string
  description = "Stable 4-char deploy suffix appended to the workspace name (workspace names need only be unique per RG, but the suffix matches the rest of the deploy for grep-ability)."
}

variable "tags" {
  type        = map(string)
  description = "Merged mandatory + operator tags."
}

variable "retention_in_days" {
  type        = number
  default     = 30
  description = "Log retention. Constitution Security Constraints requires >=30 — validation enforces it."

  validation {
    condition     = var.retention_in_days >= 30
    error_message = "retention_in_days must be at least 30 per constitution Security Constraints."
  }
}
