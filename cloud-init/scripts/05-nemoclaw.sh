#!/usr/bin/env bash
# 05-nemoclaw.sh — install NemoClaw via upstream's official installer
# (https://www.nvidia.com/nemoclaw.sh) and run a non-interactive
# `nemoclaw onboard` for the configured inference provider.
#
# Why curl|bash over the previous tarball+SHA256 approach:
# upstream NemoClaw doesn't ship release tarballs; it ships an
# installer script that clones the pinned tag and runs scripts/
# install.sh from that ref. Reproducibility comes from
# NEMOCLAW_INSTALL_TAG (pinned to ${nemoclaw_version}) — the
# installer git-clones --depth 1 --branch <tag>, so the install is
# bit-for-bit reproducible at the chosen tag.
#
# Why no systemd unit (vs. the v0.1 design): NemoClaw is CLI-driven,
# not a daemon. OpenShell + Docker + k3s run as their own services
# under NemoClaw's management. Operator runs `nemoclaw <name> connect`
# from a Tailscale SSH session to enter the sandbox.
#
# Principle II compliance: OpenShell intercepts inference traffic on
# the host (the agent talks to inference.local; OpenShell forwards
# to the real provider). Provider credentials never enter the
# sandbox. See docs/THREAT_MODEL.md §"Mediation channel".
#
# Inputs (env vars set by cloud-init runcmd, templated by Terraform):
#   NEMOCLAW_VERSION        Required. Upstream release tag (e.g. v0.0.26).
#                           Validated by terraform/root/variables.tf.
#   NEMOCLAW_OPERATOR_USER  User account that owns the install. NemoClaw's
#                           installer "runs as your normal user, into
#                           user-local directories" per upstream docs;
#                           we run it as this account via sudo -u.
#   KV_NAME                 Key Vault holding foundry-api-key.
#   FOUNDRY_SECRET_NAME     Secret name (default: foundry-api-key).
#   FOUNDRY_BASE_URL        OpenAI-compatible base URL of the Foundry
#                           endpoint (e.g. https://my.cognitiveservices
#                           .azure.com/openai/v1).
#   FOUNDRY_MODEL           Model name = the Foundry deployment name
#                           (e.g. epl-gpt-4o).
#   NEMOCLAW_SANDBOX_NAME   Sandbox name (default: nemoclaw).
#   NEMOCLAW_POLICY_MODE    suggested | custom | skip (default suggested).

set -euo pipefail

: "${NEMOCLAW_VERSION:?missing NEMOCLAW_VERSION}"
: "${KV_NAME:?missing KV_NAME}"
: "${FOUNDRY_BASE_URL:?missing FOUNDRY_BASE_URL}"
: "${FOUNDRY_MODEL:?missing FOUNDRY_MODEL}"

NEMOCLAW_OPERATOR_USER="${NEMOCLAW_OPERATOR_USER:-azureuser}"
FOUNDRY_SECRET_NAME="${FOUNDRY_SECRET_NAME:-foundry-api-key}"
NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-nemoclaw}"
NEMOCLAW_POLICY_MODE="${NEMOCLAW_POLICY_MODE:-suggested}"

# ─── Ensure operator user exists ──────────────────────────────────
#
# NemoClaw installs into the operator's home directory via nvm + npm.
# `azureuser` is created by Azure with a real home dir; we just
# ensure it has the directories the installer needs.
echo "[05-nemoclaw] ensuring operator user '$NEMOCLAW_OPERATOR_USER' is set up"
if ! getent passwd "$NEMOCLAW_OPERATOR_USER" > /dev/null; then
  echo "[05-nemoclaw] FATAL: operator user '$NEMOCLAW_OPERATOR_USER' does not exist." >&2
  echo "[05-nemoclaw] Azure usually creates the admin_username on Linux VMs;" >&2
  echo "[05-nemoclaw] verify Terraform's azurerm_linux_virtual_machine." >&2
  exit 1
fi

OPERATOR_HOME="$(getent passwd "$NEMOCLAW_OPERATOR_USER" | cut -d: -f6)"
install -d -m 0700 -o "$NEMOCLAW_OPERATOR_USER" -g "$NEMOCLAW_OPERATOR_USER" "$OPERATOR_HOME/.nemoclaw"

# Operator must be in the docker group — NemoClaw drives Docker for
# OpenShell + the sandbox. 02-docker.sh installed the daemon; we
# add the user here.
if ! id -nG "$NEMOCLAW_OPERATOR_USER" | tr ' ' '\n' | grep -qx docker; then
  echo "[05-nemoclaw] adding $NEMOCLAW_OPERATOR_USER to docker group"
  usermod -aG docker "$NEMOCLAW_OPERATOR_USER"
fi

# ─── Fetch Foundry API key from Key Vault ─────────────────────────
#
# Cloud-init runs as root with the VM's managed identity attached.
# We fetch the secret here, hand it to the NemoClaw installer via
# env var, then unset locally. The installer hands it to OpenShell
# which persists the credential in the operator's user-local config
# (~/.nemoclaw/) — that's NemoClaw upstream's design and the trust
# boundary.

echo "[05-nemoclaw] authenticating to Azure via VM managed identity"
az login --identity --output none

echo "[05-nemoclaw] fetching $FOUNDRY_SECRET_NAME from Key Vault $KV_NAME"
FOUNDRY_API_KEY="$(
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$FOUNDRY_SECRET_NAME" \
    --query value -o tsv
)"

if [[ -z "$FOUNDRY_API_KEY" || "$FOUNDRY_API_KEY" == PLACEHOLDER* ]]; then
  echo "[05-nemoclaw] FATAL: $FOUNDRY_SECRET_NAME is empty or still the Terraform placeholder." >&2
  echo "[05-nemoclaw]   Run: az keyvault secret set --vault-name $KV_NAME --name $FOUNDRY_SECRET_NAME --value <real-key>" >&2
  echo "[05-nemoclaw]   Then re-run cloud-init or this script via Run Command." >&2
  exit 1
fi

# ─── Run upstream installer non-interactively ─────────────────────
#
# NEMOCLAW_INSTALL_TAG pins the install to a specific git ref —
# the installer clones that branch with --depth 1 and runs
# scripts/install.sh from it. Reproducibility per Principle V.
#
# NEMOCLAW_PROVIDER=custom is "Other OpenAI-compatible endpoint" per
# docs/inference/inference-options.md — Azure Foundry exposes an
# OpenAI-compatible /openai/v1/ surface that NemoClaw's `custom`
# provider hits cleanly. COMPATIBLE_API_KEY is the credential env
# var for this provider.
#
# The installer runs as the operator user (sudo -u). `runuser -l`
# is preferred over `sudo -u` here because it sets up a full login
# environment (PATH, HOME, etc.) which the installer expects.

echo "[05-nemoclaw] running NemoClaw installer pinned to $NEMOCLAW_VERSION"

INSTALLER_LOG="$OPERATOR_HOME/.nemoclaw/installer.log"
install -m 0600 -o "$NEMOCLAW_OPERATOR_USER" -g "$NEMOCLAW_OPERATOR_USER" /dev/null "$INSTALLER_LOG"

# Construct the env block for the installer. We keep the API key in
# a single env var so it doesn't bleed into the surrounding shell's
# `env` listing or get logged by `set -x` in subshells.
export FOUNDRY_API_KEY

runuser -l "$NEMOCLAW_OPERATOR_USER" -- bash -c '
  set -euo pipefail
  cd "$HOME"
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
    NEMOCLAW_INSTALL_TAG='"'$NEMOCLAW_VERSION'"' \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
    NEMOCLAW_PROVIDER=custom \
    NEMOCLAW_MODEL='"'$FOUNDRY_MODEL'"' \
    NEMOCLAW_SANDBOX_NAME='"'$NEMOCLAW_SANDBOX_NAME'"' \
    NEMOCLAW_POLICY_MODE='"'$NEMOCLAW_POLICY_MODE'"' \
    COMPATIBLE_API_KEY="$FOUNDRY_API_KEY" \
    COMPATIBLE_BASE_URL='"'$FOUNDRY_BASE_URL'"' \
    bash 2>&1
' >> "$INSTALLER_LOG" 2>&1 || {
  echo "[05-nemoclaw] FATAL: installer failed. See $INSTALLER_LOG (last 80 lines):" >&2
  tail -n 80 "$INSTALLER_LOG" >&2
  unset FOUNDRY_API_KEY
  exit 1
}

# Scrub the API key from this script's environment. The installer
# has handed it to OpenShell which persisted it; we don't need it
# in this process anymore.
unset FOUNDRY_API_KEY

# ─── Smoke test: nemoclaw status as the operator ──────────────────
#
# `nemoclaw status` is upstream's documented health command. If
# the installer + onboard succeeded, this exits 0 and prints the
# sandbox state.

echo "[05-nemoclaw] running smoke test: nemoclaw status"
if runuser -l "$NEMOCLAW_OPERATOR_USER" -- bash -c 'nemoclaw status' >> "$INSTALLER_LOG" 2>&1; then
  echo "[05-nemoclaw] nemoclaw status exited 0 — install + onboard succeeded."
else
  echo "[05-nemoclaw] WARNING: nemoclaw status returned non-zero." >&2
  echo "[05-nemoclaw]   See $INSTALLER_LOG for details." >&2
  echo "[05-nemoclaw]   Common cause: validation-time call to the Foundry endpoint failed." >&2
  echo "[05-nemoclaw]   Fix: verify FOUNDRY_BASE_URL + FOUNDRY_MODEL + the secret value, then re-run." >&2
fi

echo "[05-nemoclaw] install complete at $NEMOCLAW_VERSION (sandbox: $NEMOCLAW_SANDBOX_NAME, log: $INSTALLER_LOG)"
