# Operator-facing input variables.
#
# Source-of-truth contract: specs/001-hardened-nemoclaw-deploy/contracts/tfvars-inputs.md
#
# Validation rule philosophy (constitution Principle V):
#   - Allowlist beats denylist.
#   - Reject insecure inputs at plan time, not after apply.
#   - No secrets here, ever — Foundry API key + Tailscale auth key
#     live in Key Vault and are placed there out of band.

# ─── Subscription / region ─────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Personal Azure subscription ID this deployment targets. MUST be different from any production subscription."

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription GUID (8-4-4-4-12 lowercase hex)."
  }
}

variable "location" {
  type        = string
  default     = "centralus"
  description = "Azure region. Default centralus per the operator's existing personal infrastructure (see README region trade-off note)."

  validation {
    condition     = contains(["eastus", "eastus2", "centralus", "westus2", "westus3", "northeurope", "westeurope"], var.location)
    error_message = "location must be one of: eastus, eastus2, centralus, westus2, westus3, northeurope, westeurope."
  }
}

# ─── VM ────────────────────────────────────────────────────────────

variable "vm_sku" {
  type        = string
  default     = "Standard_B4als_v2"
  description = "VM size. Must satisfy NemoClaw's verified upstream minimum (4 vCPU, 8 GB RAM)."

  validation {
    condition = contains([
      "Standard_B4als_v2",
      "Standard_B4as_v2",
      "Standard_B4ms",
      "Standard_D4as_v5",
      "Standard_D4s_v5",
    ], var.vm_sku)
    error_message = "vm_sku must be one of the allowlisted ≥4vCPU/≥8GB SKUs (Standard_B4als_v2, Standard_B4as_v2, Standard_B4ms, Standard_D4as_v5, Standard_D4s_v5). Add to the list in variables.tf only with explicit justification of cost & capability."
  }
}

# ─── NemoClaw ──────────────────────────────────────────────────────

variable "nemoclaw_version" {
  type        = string
  description = "Upstream NemoClaw release tag (e.g. v0.3.1). MUST NOT be 'main', 'latest', or 'head' — pinning is non-negotiable per constitution Principle V."

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+(-[\\w.]+)?$", var.nemoclaw_version))
    error_message = "nemoclaw_version must match ^v\\d+\\.\\d+\\.\\d+(-pre-release)?$ (e.g. v0.3.1, v1.2.3-rc1). 'main' / 'latest' / 'head' are rejected."
  }
}

# ─── Foundry ───────────────────────────────────────────────────────

variable "foundry_endpoint" {
  type        = string
  description = "Azure AI Foundry endpoint URL NemoClaw will call. Per spec Q2, the endpoint URL is non-secret and lives in tfvars (not Key Vault)."

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(/.*)?$", var.foundry_endpoint))
    error_message = "foundry_endpoint must be an https:// URL."
  }
}

variable "foundry_deployments" {
  type = map(object({
    model       = string
    api_version = string
  }))
  description = "Map of deployment-name → {model, api_version}. At least one entry required."

  validation {
    condition     = length(var.foundry_deployments) > 0
    error_message = "foundry_deployments must contain at least one entry."
  }
}

variable "foundry_primary_deployment_key" {
  type        = string
  default     = "primary"
  description = "Map-key in foundry_deployments designating the deployment NemoClaw treats as primary. Its api_version flows into the systemd unit's Environment= directive (cloud-init substitution). Default 'primary' aligns with the personal.tfvars.example template."

  validation {
    condition     = can(regex("^[A-Za-z0-9-_]+$", var.foundry_primary_deployment_key))
    error_message = "foundry_primary_deployment_key must be alphanumeric/hyphen/underscore."
  }
}

# ─── Tailscale ─────────────────────────────────────────────────────

variable "tailscale_tag" {
  type        = string
  default     = "tag:nemoclaw"
  description = "Tailscale tag advertised by the VM. The operator's tailnet ACL should reference this tag to scope which devices can reach the VM."

  validation {
    condition     = can(regex("^tag:[a-z0-9-]+$", var.tailscale_tag))
    error_message = "tailscale_tag must match ^tag:[a-z0-9-]+$ (e.g. tag:nemoclaw)."
  }
}

# ─── Auto-shutdown ─────────────────────────────────────────────────

variable "auto_shutdown_enabled" {
  type        = bool
  default     = true
  description = "Whether to provision the nightly VM-deallocation schedule. Default ON for the personal-budget envelope (spec SC-005)."
}

variable "auto_shutdown_local_time" {
  type        = string
  default     = "21:00"
  description = "Local time at which the VM deallocates daily (HH:MM, 24-hour)."

  validation {
    condition     = can(regex("^([01]\\d|2[0-3]):[0-5]\\d$", var.auto_shutdown_local_time))
    error_message = "auto_shutdown_local_time must be HH:MM (00:00–23:59)."
  }
}

variable "auto_shutdown_tz" {
  type        = string
  default     = "America/Los_Angeles"
  description = "IANA timezone for the shutdown schedule. Allowlist matches Azure's documented DevTest Labs timezone set."

  validation {
    # Subset of the Azure-supported IANA tz names that match the
    # operator's likely deploy targets. Extend with explicit
    # justification.
    condition = contains([
      "America/Los_Angeles",
      "America/Denver",
      "America/Chicago",
      "America/New_York",
      "UTC",
      "Europe/London",
      "Europe/Berlin",
      "Europe/Madrid",
      "Asia/Tokyo",
      "Asia/Singapore",
      "Australia/Sydney",
    ], var.auto_shutdown_tz)
    error_message = "auto_shutdown_tz must be one of the allowlisted IANA names. Extend variables.tf with justification if you need another."
  }
}

# ─── Tagging ───────────────────────────────────────────────────────

variable "owner" {
  type        = string
  description = "Owner tag value — email address or GitHub handle. Required, no default."

  validation {
    condition     = can(regex("^[\\w.+-]+@[\\w-]+\\.[\\w.-]+$", var.owner)) || can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", var.owner))
    error_message = "owner must be an email address or a GitHub username (1-39 chars, alphanumeric + hyphens, no leading hyphen)."
  }
}

variable "cost_center" {
  type        = string
  default     = "personal"
  description = "Cost-center tag value. Default 'personal' per constitution Cost & Operational Constraints."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged with the four mandatory tags. Operator-supplied keys CANNOT override project/owner/cost-center/managed-by — locals.tf enforces this with merge(var.tags, local.mandatory_tags)."
}

# ─── Operator data-plane IP allowlist ──────────────────────────────

variable "resource_group_name" {
  type        = string
  default     = "rg-nemoclaw"
  description = "Name of the single shared resource group (created by terraform/bootstrap/). Root reads it via data source — bootstrap MUST have applied successfully first. Override only if you set a non-default value in bootstrap."
}

variable "operator_ip_cidr" {
  type        = string
  description = "Operator's public IP as a /32 CIDR (e.g. 203.0.113.5/32). Added to the Key Vault network ACL so `az keyvault secret set` from the laptop reaches the data plane despite public_network_access_enabled=false. Constitution Principle V: rejects 0.0.0.0/32 and any malformed CIDR."

  validation {
    # `cidrhost()` returns the first host in the prefix; it errors if
    # the input is not a syntactically valid CIDR. `can()` traps the
    # error and turns it into a boolean. This catches malformed
    # octets (999.999.999.999) and wrong-arity addresses (1.2.3.4.5)
    # that a regex would silently let through.
    condition = (
      can(cidrhost(var.operator_ip_cidr, 0))
      && endswith(var.operator_ip_cidr, "/32")
      && var.operator_ip_cidr != "0.0.0.0/32"
    )
    error_message = "operator_ip_cidr must be a syntactically valid /32 single-host CIDR (e.g. 203.0.113.5/32). 0.0.0.0/32 is rejected."
  }
}
