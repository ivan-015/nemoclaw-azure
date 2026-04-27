# vm module — input contract.
#
# Owns: NIC (no public IP), Linux VM with cloud-init custom_data,
# managed-disk OS disk with platform-managed encryption, user-assigned
# MI attached.
#
# Cloud-init substitutions are done HERE, not in main.tf, so the
# module is self-contained and the parent only passes structured
# inputs.

variable "resource_group_name" {
  type        = string
  description = "Resource group for VM, NIC, OS disk."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "tags" {
  type        = map(string)
  description = "Merged mandatory + operator tags."
}

variable "name_suffix" {
  type        = string
  description = "Stable 4-char deploy suffix used in VM/NIC names."
}

# ─── Compute ──────────────────────────────────────────────────────

variable "vm_sku" {
  type        = string
  description = "VM size. Validated upstream in terraform/root/variables.tf."
}

variable "image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    # Concrete image version — Principle V (reproducibility) requires
    # a real string here, not "latest". Operator can refresh the pin
    # via (resolves the actual stable-channel current version, NOT
    # the daily-channel build that `az vm image list --all` surfaces):
    #   az vm image show \
    #     --urn "Canonical:ubuntu-24_04-lts:server:latest" \
    #     --location <region> --query name -o tsv
    # Bump on a deliberate PR with the diff visible. The OS is the
    # supply-chain root for everything cloud-init installs on top.
    version = "24.04.202604160"
  }
  description = "Marketplace image. Default Ubuntu 24.04 LTS server, pinned to a concrete version per Principle V. Override via tfvars to test newer images on a throwaway RG before bumping the default."

  validation {
    condition     = var.image.version != "latest" && var.image.version != ""
    error_message = "image.version must be a concrete Marketplace version string (e.g. 24.04.202604160). 'latest' is rejected to preserve reproducibility (Principle V)."
  }
}

variable "os_disk_size_gb" {
  type        = number
  default     = 64
  description = "OS disk size. NemoClaw + Docker layers + a few inference workloads fit in 64 GB. Bump if container images grow large."
}

# ─── Network ──────────────────────────────────────────────────────

variable "vm_subnet_id" {
  type        = string
  description = "Subnet ID where the NIC lives. From the network module."
}

# ─── Identity ─────────────────────────────────────────────────────

variable "managed_identity_id" {
  type        = string
  description = "Resource ID of the user-assigned MI to attach to the VM."
}

# ─── Cloud-init template inputs ───────────────────────────────────

variable "kv_name" {
  type        = string
  description = "Key Vault name. Cloud-init's 01-tailscale.sh fetches the Tailscale auth key from it; 05-nemoclaw.sh fetches the Foundry API key from it."
}

variable "tailscale_secret_name" {
  type        = string
  description = "Tailscale auth-key secret name."
}

variable "tailscale_tag" {
  type        = string
  description = "Tailscale tag the VM advertises."
}

variable "nemoclaw_version" {
  type        = string
  description = "Pinned NemoClaw release tag (e.g. v0.0.26). The upstream installer (https://www.nvidia.com/nemoclaw.sh) clones this ref via NEMOCLAW_INSTALL_TAG."
}

variable "nemoclaw_operator_user" {
  type        = string
  default     = "azureuser"
  description = "Linux user that owns the NemoClaw install. Upstream installs into this user's home dir via nvm + npm. Defaults to Azure's standard admin_username."
}

variable "nemoclaw_sandbox_name" {
  type        = string
  default     = "nemoclaw"
  description = "OpenShell sandbox name created by `nemoclaw onboard`. Operator references this when running `nemoclaw <name> connect`."
}

variable "nemoclaw_policy_mode" {
  type        = string
  default     = "suggested"
  description = "Policy mode for the sandbox. 'suggested' applies upstream's default policy presets; 'custom' lets the operator choose presets; 'skip' creates a sandbox with no policy."

  validation {
    condition     = contains(["suggested", "custom", "skip"], var.nemoclaw_policy_mode)
    error_message = "nemoclaw_policy_mode must be one of: suggested, custom, skip."
  }
}

variable "foundry_base_url" {
  type        = string
  description = "OpenAI-compatible base URL for the Foundry endpoint (e.g. https://my.cognitiveservices.azure.com/openai/v1). NemoClaw's `custom` provider hits this."
}

variable "foundry_model" {
  type        = string
  description = "Foundry deployment name (e.g. epl-gpt-4o). Used as the OpenAI-compatible model identifier."
}

variable "docker_version" {
  type        = string
  default     = "5:27.5.1-1~ubuntu.24.04~noble"
  description = "Pinned Docker CE version. Constitution Principle V — explicit pin."
}

variable "node_major" {
  type        = number
  default     = 22
  description = "Node major version for NodeSource. NemoClaw upstream requires 22.16+."
}

# ─── Cloud-init script paths (relative to repo root) ──────────────

variable "cloud_init_template_path" {
  type        = string
  description = "Filesystem path to bootstrap.yaml.tpl. Resolved relative to the parent module's path."
}

variable "cloud_init_scripts_dir" {
  type        = string
  description = "Filesystem path to the directory holding 01-tailscale.sh, 02-docker.sh, 03-node.sh, 05-nemoclaw.sh."
}
