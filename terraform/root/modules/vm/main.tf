# Linux VM hosting NemoClaw.
#
# Network posture (Principle I + spec FR-001/FR-002/FR-005):
#   - NIC has NO public IP. Operator reaches the VM only via Tailscale.
#   - NSG (provisioned by the network module) has zero custom inbound
#     allow rules + an explicit DenyAll outbound at priority 4096.
#   - SSH is structurally impossible: no admin_ssh_key, password auth
#     disabled, no Bastion. Operator uses Tailscale SSH (which lives
#     inside the WireGuard tunnel and never opens an Azure NSG port).
#
# Identity:
#   - One user-assigned MI from the identity module. The VM cloud-init
#     scripts and the credential-handoff binary authenticate via
#     `az login --identity`.
#
# Disk:
#   - Platform-managed encryption (constitution accepts at v1).
#     Customer-managed key is a v2 upgrade documented in the threat
#     model.
#
# Cloud-init:
#   - bootstrap.yaml.tpl is rendered HERE with all the substitutions.
#     The script bodies are read from disk via file() and base64-
#     encoded into the YAML via b64encode() so cloud-init's
#     write_files lands them verbatim (avoiding YAML quoting issues
#     on shell metacharacters).

# ─── Throwaway SSH key (API theatre — see admin_ssh_key block below) ──
#
# Azure's API forbids creating a Linux VM with
# disable_password_authentication=true unless at least one
# admin_ssh_key is supplied. We generate one here whose public half
# the VM never gets reached at (no public IP; NSG denies all inbound)
# and whose private half lives only in Terraform state. Tailscale SSH
# is the real access vector. Constitution Principle V: the keypair is
# fully reproducible — `terraform apply` regenerates if state is lost
# without prompting the operator for material.
resource "tls_private_key" "unreachable" {
  algorithm = "ED25519"
}

locals {
  # Read each cloud-init script as bytes; cloud-init's b64-decode in
  # write_files avoids shell-metacharacter quoting hazards.
  script_01_tailscale = file("${var.cloud_init_scripts_dir}/01-tailscale.sh")
  script_02_docker    = file("${var.cloud_init_scripts_dir}/02-docker.sh")
  script_03_node      = file("${var.cloud_init_scripts_dir}/03-node.sh")
  script_05_nemoclaw  = file("${var.cloud_init_scripts_dir}/05-nemoclaw.sh")

  # Stable VM hostname (also used as the Tailscale --hostname).
  # Tailscale's hostname field is a label; lowercase + hyphens only.
  vm_hostname = "nemoclaw-${var.name_suffix}"

  rendered_cloud_init = templatefile(var.cloud_init_template_path, {
    kv_name                 = var.kv_name
    tailscale_secret_name   = var.tailscale_secret_name
    tailscale_tag           = var.tailscale_tag
    tailscale_hostname      = local.vm_hostname
    docker_version          = var.docker_version
    node_major              = var.node_major
    nemoclaw_version        = var.nemoclaw_version
    nemoclaw_operator_user  = var.nemoclaw_operator_user
    nemoclaw_sandbox_name   = var.nemoclaw_sandbox_name
    nemoclaw_policy_mode    = var.nemoclaw_policy_mode
    foundry_base_url        = var.foundry_base_url
    foundry_model           = var.foundry_model
    b64_script_01_tailscale = base64encode(local.script_01_tailscale)
    b64_script_02_docker    = base64encode(local.script_02_docker)
    b64_script_03_node      = base64encode(local.script_03_node)
    b64_script_05_nemoclaw  = base64encode(local.script_05_nemoclaw)
  })
}

# ─── NIC ──────────────────────────────────────────────────────────
#
# No public_ip_address_id. Static private IP would be cosmetic;
# Tailscale handles addressing. Default dynamic private IP is fine.

resource "azurerm_network_interface" "main" {
  name                = "nic-nemoclaw-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.vm_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# ─── VM ───────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "main" {
  name                = "vm-nemoclaw-${var.name_suffix}"
  computer_name       = local.vm_hostname
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_sku
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.main.id]

  # FR-005: no SSH-key infrastructure for operator use. Tailscale
  # SSH is the only real access vector. The Azure provider, however,
  # requires admin_ssh_key whenever disable_password_authentication=
  # true, so we generate a throwaway ED25519 keypair below: the public
  # half goes on the VM, the private half lives only in Terraform
  # state, and there is no public IP / no NSG inbound rule that would
  # ever expose port 22 anyway. This is API theatre, not a real key.
  disable_password_authentication = true
  admin_username                  = "azureuser"

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.unreachable.public_key_openssh
  }

  # User-assigned MI attached. Cloud-init's `az login --identity`
  # uses this MI. Constitution Principle III: this MI has read-only
  # KV access scoped to a single vault.
  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
    # Platform-managed encryption (default). Customer-managed key is
    # a v2 upgrade per docs/THREAT_MODEL.md.
  }

  source_image_reference {
    publisher = var.image.publisher
    offer     = var.image.offer
    sku       = var.image.sku
    version   = var.image.version
  }

  # custom_data is base64-encoded bytes of the cloud-init YAML.
  custom_data = base64encode(local.rendered_cloud_init)

  # Boot diagnostics with managed storage — required for the no-network
  # debug path (US4) via `az vm boot-diagnostics get-boot-log`.
  boot_diagnostics {
    storage_account_uri = null # null => Azure-managed boot diagnostics
  }
}
