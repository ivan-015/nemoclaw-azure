# Root-stage locals.
#
# Two roles:
#   1. Mandatory-tag composition (constitution Cost & Operational
#      Constraints requires the four mandatory keys on every resource;
#      operator-supplied `var.tags` MUST NOT override them).
#   2. Globally-unique resource naming (Key Vault, etc.) using a stable
#      4-char random suffix so destroy/redeploy doesn't collide with
#      the soft-delete hold (research R7 / spec FR-026).

resource "random_string" "deploy_suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false

  # Stable across applies on the same state. To force a new suffix
  # (e.g. after a destroy that soft-deleted the Key Vault), run:
  #   terraform taint random_string.deploy_suffix && terraform apply
}

locals {
  # The four constitution-mandated tags. `merge(var.tags, ...)` order
  # below ensures these always win over any operator-supplied tag of
  # the same key.
  mandatory_tags = {
    project     = "nemoclaw-azure"
    owner       = var.owner
    cost-center = var.cost_center
    managed-by  = "terraform"
  }

  # Final tag map: operator-supplied first, mandatory tags last so
  # they cannot be overridden.
  tags = merge(var.tags, local.mandatory_tags)

  # Derived resource names. The suffix gives us deploy-time
  # uniqueness for resources that need globally-unique names.
  suffix = random_string.deploy_suffix.result

  # Key Vault names: 3–24 chars, alphanumeric + hyphen, must start
  # with a letter, must end alphanumeric. "kv-nc-" + 4 chars = 10.
  kv_name = "kv-nc-${local.suffix}"

  # User-assigned managed identity for the VM. Identity names: 3–128
  # chars, alphanumeric + hyphen + underscore.
  mi_name = "mi-nemoclaw-${local.suffix}"

  # Shared resource-group name. RG names: ≤90 chars; we keep it short.
  resource_group_name = "rg-nemoclaw-${local.suffix}"
}
