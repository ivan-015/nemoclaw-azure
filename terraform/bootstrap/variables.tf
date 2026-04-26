# Bootstrap-stage inputs.
#
# Kept minimal — bootstrap stands up only the state backend. The full
# operator-facing variable surface is in terraform/root/variables.tf.

variable "subscription_id" {
  type        = string
  description = "Personal Azure subscription ID. Must be different from any production subscription."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription GUID (8-4-4-4-12 lowercase hex)."
  }
}

variable "location" {
  type        = string
  default     = "centralus"
  description = "Azure region for the state backend RG and storage account."

  validation {
    condition     = contains(["eastus", "eastus2", "centralus", "westus2", "westus3", "northeurope", "westeurope"], var.location)
    error_message = "location must be one of: eastus, eastus2, centralus, westus2, westus3, northeurope, westeurope."
  }
}

variable "owner" {
  type        = string
  description = "Owner tag value (email or GitHub handle). Required — no default."

  validation {
    condition     = can(regex("^[\\w.+-]+@[\\w-]+\\.[\\w.-]+$", var.owner)) || can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.owner))
    error_message = "owner must be an email address or a GitHub username (1-39 chars, alphanumeric + hyphens, no leading hyphen)."
  }
}
