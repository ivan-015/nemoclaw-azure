#cloud-config
# Cloud-init bootstrap for NemoClaw VM.
#
# Rendered by Terraform via templatefile() in
# terraform/root/modules/vm/main.tf. The placeholders $${...} below
# are substituted at apply time with values from:
#   - the keyvault module (kv_name)
#   - the operator's tfvars (nemoclaw_version, foundry_endpoint,
#     foundry_deployments rendered as JSON, foundry_api_version,
#     tailscale_tag, vm hostname)
#   - the network/identity modules (no current substitutions but
#     reserved for future use)
#
# Spec FR-018: zero manual intervention during a single apply. The
# scripts here are invoked in the order documented in plan.md and
# fail loudly on error so a partial cloud-init does not leave the
# VM in a confusing half-state.

# Wait until cloud-init's network bring-up has finished before any
# of these commands run. Cloud-init's runcmd already runs late, but
# being explicit guards against package mirrors not yet being
# reachable.

package_update: true
package_upgrade: false

write_files:
  # Cloud-init scripts dropped to disk. Marked executable in runcmd.

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

  - path: /opt/nemoclaw-bootstrap/04-credential-handoff.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_04_credential_handoff}

  - path: /opt/nemoclaw-bootstrap/05-nemoclaw.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${b64_script_05_nemoclaw}

  # Rendered systemd unit. At US1 ExecStartPre is /bin/true (US2 wires
  # the real credential handoff). The Terraform-rendered content is
  # base64-encoded so cloud-init does not double-process the unit's
  # `$${...}` directives (systemd's own template syntax).
  - path: /etc/systemd/system/nemoclaw.service
    permissions: '0644'
    owner: root:root
    encoding: b64
    content: ${b64_systemd_unit}

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

  # ── 04: Credential handoff (US1 stub; US2 overwrites in T032) ────
  - |
    set -eu
    /opt/nemoclaw-bootstrap/04-credential-handoff.sh

  # ── 05: NemoClaw install (enables but does NOT start the unit) ───
  - |
    set -eu
    export NEMOCLAW_VERSION='${nemoclaw_version}'
    export NEMOCLAW_RELEASE_URL_BASE='${nemoclaw_release_url_base}'
    export FOUNDRY_ENDPOINT='${foundry_endpoint}'
    export FOUNDRY_DEPLOYMENTS_JSON='${foundry_deployments_json}'
    export FOUNDRY_API_VERSION='${foundry_api_version}'
    /opt/nemoclaw-bootstrap/05-nemoclaw.sh

final_message: "[cloud-init] nemoclaw-azure bootstrap complete in $UPTIME seconds"
