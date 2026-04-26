# Root-stage composition.
#
# Wires the five v1 modules in dependency order:
#   network ─┬─▶ keyvault ─▶ vm
#   identity ┘
#   log-analytics ─▶ keyvault (diagnostic settings)
#                  ─▶ network  (NSG flow logs Traffic Analytics)
#
# Resource group is provisioned here (not inside a module) because
# every module needs its name, and a module that produces an RG is
# awkward when the RG is shared.

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

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

# ─── Independent foundation modules (parallel) ────────────────────

module "log_analytics" {
  source = "./modules/log-analytics"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  name_suffix         = local.suffix
  tags                = local.tags
  retention_in_days   = 30

  depends_on = [azurerm_resource_group.main]
}

module "identity" {
  source = "./modules/identity"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  name                = local.mi_name
  tags                = local.tags

  depends_on = [azurerm_resource_group.main]
}

module "network" {
  source = "./modules/network"

  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  name_suffix                = local.suffix
  tags                       = local.tags
  log_analytics_workspace_id = module.log_analytics.id

  depends_on = [
    azurerm_resource_group.main,
    module.log_analytics,
  ]
}

# ─── Key Vault depends on network (subnet) + identity (MI) ────────

module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = azurerm_resource_group.main.name
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

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  name_suffix         = local.suffix
  tags                = local.tags

  vm_sku = var.vm_sku

  vm_subnet_id               = module.network.vm_subnet_id
  managed_identity_id        = module.identity.id
  managed_identity_client_id = module.identity.client_id

  kv_name               = module.keyvault.name
  tailscale_secret_name = module.keyvault.tailscale_secret_name
  tailscale_tag         = var.tailscale_tag

  nemoclaw_version    = var.nemoclaw_version
  foundry_endpoint    = var.foundry_endpoint
  foundry_deployments = var.foundry_deployments
  foundry_api_version = var.foundry_deployments[var.foundry_primary_deployment_key].api_version

  cloud_init_template_path   = "${path.module}/../../cloud-init/bootstrap.yaml.tpl"
  systemd_unit_template_path = "${path.module}/../../cloud-init/scripts/nemoclaw.service.tpl"
  cloud_init_scripts_dir     = "${path.module}/../../cloud-init/scripts"

  depends_on = [
    module.keyvault,
    module.identity,
    module.network,
  ]
}
