# Root-stage composition.
#
# Wires the five v1 modules in dependency order:
#   network ─┬─▶ keyvault ─▶ vm
#   identity ┘
#   log-analytics ─▶ keyvault (diagnostic settings)
#                  ─▶ network  (NSG flow logs Traffic Analytics)
#
# The single shared resource group is created by terraform/bootstrap/
# (it also holds the state SA). This stage reads it via data source
# and deploys the workload INTO it. `terraform destroy` here removes
# only the workload resources — bootstrap's RG and state SA stay
# intact. Full teardown = destroy here, then destroy in bootstrap.

# Pull the operator's AAD identity to flow into the keyvault module's
# operator_principal_id (auto-grant Key Vault Secrets Officer for
# between-applies seeding).
data "azurerm_client_config" "current" {}

# Cross-variable guard: foundry_primary_deployment_key MUST exist as
# a key in foundry_deployments. A regular `validation` block on
# either variable can't reference the other; a precondition on a
# `terraform_data` resource can. This fails at plan time with a
# human-readable error rather than crashing later when main.tf
# dereferences var.foundry_deployments[var.foundry_primary_deployment_key].
resource "terraform_data" "input_validation" {
  input = "input-validation-marker"

  lifecycle {
    precondition {
      condition     = contains(keys(var.foundry_deployments), var.foundry_primary_deployment_key)
      error_message = "foundry_primary_deployment_key '${var.foundry_primary_deployment_key}' is not a key in foundry_deployments. Defined keys: ${join(", ", keys(var.foundry_deployments))}."
    }
  }
}

# Read the single shared RG that terraform/bootstrap/ created.
# Root deploys workload resources INTO this RG but does not own it —
# `terraform destroy` here removes only the workload, leaving the RG
# and the bootstrap state SA intact. For full teardown, run
# `terraform destroy` in terraform/bootstrap/ as well (after this).
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# ─── Independent foundation modules (parallel) ────────────────────

module "log_analytics" {
  source = "./modules/log-analytics"

  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name_suffix         = local.suffix
  tags                = local.tags
  retention_in_days   = 30

  depends_on = [data.azurerm_resource_group.main]
}

module "identity" {
  source = "./modules/identity"

  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name                = local.mi_name
  tags                = local.tags

  depends_on = [data.azurerm_resource_group.main]
}

module "network" {
  source = "./modules/network"

  resource_group_name        = data.azurerm_resource_group.main.name
  location                   = var.location
  name_suffix                = local.suffix
  tags                       = local.tags
  log_analytics_workspace_id = module.log_analytics.id

  depends_on = [
    data.azurerm_resource_group.main,
    module.log_analytics,
  ]
}

# ─── Key Vault depends on network (subnet) + identity (MI) ────────

module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name                = local.kv_name
  tags                = local.tags

  tenant_id                        = data.azurerm_client_config.current.tenant_id
  vm_subnet_id                     = module.network.vm_subnet_id
  vm_managed_identity_principal_id = module.identity.principal_id
  operator_principal_id            = data.azurerm_client_config.current.object_id
  operator_ip_cidr                 = var.operator_ip_cidr
  log_analytics_workspace_id       = module.log_analytics.id

  depends_on = [
    module.network,
    module.identity,
    module.log_analytics,
  ]
}

# ─── VM depends on KV (so cloud-init can read the Tailscale auth ──
# ─── key on first boot) + identity (MI) + network (subnet) ────────

module "vm" {
  source = "./modules/vm"

  resource_group_name = data.azurerm_resource_group.main.name
  location            = var.location
  name_suffix         = local.suffix
  tags                = local.tags

  vm_sku = var.vm_sku

  vm_subnet_id        = module.network.vm_subnet_id
  managed_identity_id = module.identity.id

  kv_name               = module.keyvault.name
  tailscale_secret_name = module.keyvault.tailscale_secret_name
  tailscale_tag         = var.tailscale_tag

  nemoclaw_version = var.nemoclaw_version
  # Foundry endpoint passed to NemoClaw's `custom` (= "Other OpenAI-
  # compatible endpoint") provider. Azure Foundry exposes the OpenAI-
  # compatible surface at /openai/v1 on the resource hostname; we
  # build the full base URL by appending /openai/v1 to whatever
  # var.foundry_endpoint resolves to.
  foundry_base_url = "${var.foundry_endpoint}/openai/v1"
  foundry_model    = var.foundry_primary_deployment_key

  cloud_init_template_path = "${path.module}/../../cloud-init/bootstrap.yaml.tpl"
  cloud_init_scripts_dir   = "${path.module}/../../cloud-init/scripts"

  depends_on = [
    module.keyvault,
    module.identity,
    module.network,
  ]
}

# ─── Auto-shutdown (US3 / T036) ───────────────────────────────────
#
# Daily VM deallocation per spec SC-005/SC-006. Lives at the root
# rather than inside the vm module so the vm module stays reusable
# for non-personal profiles (where shutdown might be undesired or
# scheduled differently).
#
# Per spec Q1 (no alerting in v1), notification_settings.enabled is
# false — the deallocation simply happens, the operator notices on
# the next attempt to use the VM and runs `az vm start` (the
# start_command output prints the exact invocation).
#
# count = 0 when var.auto_shutdown_enabled is false (the dev profile
# in dev.tfvars.example) so iteration days don't fight the schedule.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  count = var.auto_shutdown_enabled ? 1 : 0

  virtual_machine_id = module.vm.id
  location           = var.location
  enabled            = true

  # Azure expects HHMM (4 digits, no separator). The variable's
  # validation already enforced HH:MM with a colon, so this is a
  # safe transform.
  daily_recurrence_time = replace(var.auto_shutdown_local_time, ":", "")

  # Map IANA → Windows timezone IDs (locals.tf). The variable
  # validation guarantees the key exists in the map.
  timezone = local.timezone_iana_to_windows[var.auto_shutdown_tz]

  notification_settings {
    enabled = false
  }

  tags = local.tags
}
