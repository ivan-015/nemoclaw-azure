#cloud-config
# Cloud-init bootstrap for NemoClaw VM.
#
# Rendered by Terraform via templatefile() in
# terraform/root/modules/vm/main.tf. The placeholders $${...} below
# are substituted at apply time with values from the keyvault module
# (kv_name), the operator's tfvars (nemoclaw_version, foundry_*,
# tailscale_tag, vm hostname), and a few defaults from the vm module.
#
# Spec FR-018: zero manual intervention during a single apply. The
# four scripts run in order and fail loudly on error so a partial
# cloud-init does not leave the VM in a confusing half-state.

package_update: true
package_upgrade: false

write_files:
  # Cloud-init scripts. The set -o pipefail option in scripts is in
  # their own bash shebangs (they are bash, not /bin/sh), so the
  # runcmd wrappers below stay portable.

  - path: /opt/nemoclaw-bootstrap/01-tailscale.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_01_tailscale}

  - path: /opt/nemoclaw-bootstrap/02-docker.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_02_docker}

  - path: /opt/nemoclaw-bootstrap/03-node.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_03_node}

  - path: /opt/nemoclaw-bootstrap/05-nemoclaw.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_05_nemoclaw}

runcmd:
  # ── 01: Tailscale ────────────────────────────────────────────────
  - |
    set -eu
    export KV_NAME='${kv_name}'
    export TAILSCALE_SECRET='${tailscale_secret_name}'
    export TAILSCALE_TAG='${tailscale_tag}'
    export TAILSCALE_HOSTNAME='${tailscale_hostname}'
    /opt/nemoclaw-bootstrap/01-tailscale.sh

  # ── 02: Docker ───────────────────────────────────────────────────
  - |
    set -eu
    export DOCKER_VERSION='${docker_version}'
    /opt/nemoclaw-bootstrap/02-docker.sh

  # ── 03: Node ─────────────────────────────────────────────────────
  - |
    set -eu
    export NODE_MAJOR='${node_major}'
    /opt/nemoclaw-bootstrap/03-node.sh

  # ── 05: NemoClaw install + onboard (curl|bash + non-interactive) ─
  - |
    set -eu
    export NEMOCLAW_VERSION='${nemoclaw_version}'
    export NEMOCLAW_OPERATOR_USER='${nemoclaw_operator_user}'
    export NEMOCLAW_SANDBOX_NAME='${nemoclaw_sandbox_name}'
    export NEMOCLAW_POLICY_MODE='${nemoclaw_policy_mode}'
    export KV_NAME='${kv_name}'
    export FOUNDRY_SECRET_NAME='foundry-api-key'
    export FOUNDRY_BASE_URL='${foundry_base_url}'
    export FOUNDRY_MODEL='${foundry_model}'
    /opt/nemoclaw-bootstrap/05-nemoclaw.sh

final_message: "[cloud-init] nemoclaw-azure bootstrap complete in $UPTIME seconds"
