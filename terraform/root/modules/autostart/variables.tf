variable "resource_group_name" {
  type        = string
  description = "Resource group hosting the Automation Account (same RG as the VM)."
}

variable "location" {
  type        = string
  description = "Azure region. Should match the VM's region for low-latency runbook execution."
}

variable "name_suffix" {
  type        = string
  description = "4-char deploy suffix from root locals.tf (used in resource names)."
}

variable "tags" {
  type        = map(string)
  description = "Tag map (must include the four constitution-mandated tags)."
}

variable "subscription_id" {
  type        = string
  description = "Subscription ID — needed by the runbook's Set-AzContext call."
}

variable "vm_resource_id" {
  type        = string
  description = "Full ARM ID of the VM. Used as the role-assignment scope (least privilege)."
}

variable "vm_resource_group_name" {
  type        = string
  description = "RG name the VM lives in (passed to Start-AzVM)."
}

variable "vm_name" {
  type        = string
  description = "VM resource name (passed to Start-AzVM)."
}

variable "auto_start_local_time" {
  type        = string
  description = "Local time the VM wakes daily (HH:MM)."

  validation {
    condition     = can(regex("^([01]\\d|2[0-3]):[0-5]\\d$", var.auto_start_local_time))
    error_message = "auto_start_local_time must be HH:MM (00:00–23:59)."
  }
}

variable "auto_start_tz" {
  type        = string
  description = "IANA timezone name (display label only; used in the schedule description)."
}

variable "tz_offset_hint" {
  type        = string
  description = "Static UTC offset for the configured tz (e.g. '-08:00' for LA winter). Used only to anchor the FIRST run within Azure's 5min-6day future window. After that, the schedule's tz_windows field handles DST. Acceptable to pass either the standard or daylight offset; first fire may be off by an hour but daily fires after that are correct."

  validation {
    condition     = can(regex("^[-+](0\\d|1[0-3]):[0-5]\\d$", var.tz_offset_hint))
    error_message = "tz_offset_hint must be a fixed UTC offset like -08:00 or +09:00."
  }
}
