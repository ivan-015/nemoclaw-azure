# vm module — input contract.
#
# Owns: NIC (no public IP), Linux VM with cloud-init custom_data,
# managed-disk OS disk with platform-managed encryption, user-assigned
# MI attached.
#
# Cloud-init substitutions and the systemd unit render are done HERE,
# not in main.tf, so the module is self-contained and the parent only
# passes structured inputs.

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
    # via:
    #   az vm image list \
    #     --publisher Canonical --offer ubuntu-24_04-lts --sku server \
    #     --all --query "reverse(sort_by([], &version))[0].version" -o tsv
    # Bump on a deliberate PR with the diff visible. The OS is the
    # supply-chain root for everything cloud-init installs on top.
    version = "24.04.202504150"
  }
  description = "Marketplace image. Default Ubuntu 24.04 LTS server, pinned to a concrete version per Principle V. Override via tfvars to test newer images on a throwaway RG before bumping the default."

  validation {
    condition     = var.image.version != "latest" && var.image.version != ""
    error_message = "image.version must be a concrete Marketplace version string (e.g. 24.04.202504150). 'latest' is rejected to preserve reproducibility (Principle V)."
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

variable "managed_identity_client_id" {
  type        = string
  description = "Client ID of the MI. Currently unused by cloud-init (only one MI is attached) but reserved so cloud-init can use --username when multiple MIs are added later."
}

# ─── Cloud-init template inputs ───────────────────────────────────

variable "kv_name" {
  type        = string
  description = "Key Vault name. Cloud-init's 01-tailscale.sh fetches the Tailscale auth key from it."
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
  description = "Pinned NemoClaw release tag."
}

variable "nemoclaw_release_url_base" {
  type        = string
  default     = "https://github.com/NVIDIA/NemoClaw/releases/download"
  description = "GitHub Releases URL base. Override only if upstream moves."
}

variable "foundry_endpoint" {
  type        = string
  description = "Azure AI Foundry endpoint URL."
}

variable "foundry_deployments" {
  type = map(object({
    model       = string
    api_version = string
  }))
  description = "Map of deployment name → {model, api_version}. JSON-rendered into cloud-init."
}

variable "foundry_api_version" {
  type        = string
  description = "API version for the credential-handoff env (templated in the systemd unit). For now we surface the api_version of the *primary* deployment as a top-level value; if NemoClaw needs per-deployment versions, this becomes a JSON map."
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
  description = "Filesystem path to bootstrap.yaml.tpl. Resolved relative to the parent module's path. Default constructed in main.tf via path.module."
}

variable "systemd_unit_template_path" {
  type        = string
  description = "Filesystem path to nemoclaw.service.tpl."
}

variable "cloud_init_scripts_dir" {
  type        = string
  description = "Filesystem path to the directory holding 01-tailscale.sh, 02-docker.sh, etc."
}
