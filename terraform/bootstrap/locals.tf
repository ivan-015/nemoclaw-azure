# Bootstrap-stage locals.
#
# The bootstrap stage runs in its own Terraform state (local), so it
# cannot consume terraform/root/locals.tf. Constitution Cost &
# Operational Constraints requires the four mandatory tags on EVERY
# Azure resource — including the bootstrap RG and storage account —
# so we redefine the tag map here.

locals {
  mandatory_tags = {
    project     = "nemoclaw-azure"
    owner       = var.owner
    cost-center = "personal"
    managed-by  = "terraform"
  }

  # Storage account names: 3–24 chars, lowercase alphanumeric, globally
  # unique. We compose: "tfstate" + 4-char random suffix = 11 chars,
  # well under 24. The suffix is regenerated only on explicit `taint`.
  storage_account_name = "tfstate${random_string.suffix.result}"

  state_container_name = "tfstate"
}
