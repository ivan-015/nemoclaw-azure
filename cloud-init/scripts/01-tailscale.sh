#!/usr/bin/env bash
# 01-tailscale.sh — install Tailscale + Azure CLI, fetch the
# tailscale-auth-key from Key Vault via the VM's user-assigned
# managed identity, register the node, scrub the key in-memory.
#
# Spec FR-003, FR-012. Research R3 (kernel mode), R5 (auth key
# lifecycle).
#
# Inputs (env vars set by the cloud-init `runcmd:` invocation,
# rendered from Terraform via templatefile()):
#   KV_NAME              Key Vault name (e.g. kv-nc-1a2b)
#   TAILSCALE_SECRET     Secret name (e.g. tailscale-auth-key)
#   TAILSCALE_TAG        Advertised tag (e.g. tag:nemoclaw)
#   TAILSCALE_HOSTNAME   Hostname to register on the tailnet
#   MI_CLIENT_ID         Optional: user-assigned MI client_id (only
#                        needed if the VM has multiple MIs attached;
#                        omitted in v1 since we attach exactly one)

set -euo pipefail

: "${KV_NAME:?missing KV_NAME}"
: "${TAILSCALE_SECRET:?missing TAILSCALE_SECRET}"
: "${TAILSCALE_TAG:?missing TAILSCALE_TAG}"
: "${TAILSCALE_HOSTNAME:?missing TAILSCALE_HOSTNAME}"

echo "[01-tailscale] installing tailscale + azure-cli"

# Tailscale's official package — see pkgs.tailscale.com.
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list

# Azure CLI's official package — see learn.microsoft.com/cli/azure/install-azure-cli-linux-apt
mkdir -p /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod go+r /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" \
  > /etc/apt/sources.list.d/azure-cli.list

apt-get update
apt-get install -y tailscale azure-cli

systemctl enable --now tailscaled

echo "[01-tailscale] authenticating to Azure via managed identity"
# az login --identity uses the IMDS endpoint at 169.254.169.254. With
# only one MI attached this works without --username; if multiple MIs
# were attached we'd pass --username "$MI_CLIENT_ID".
az login --identity --output none

echo "[01-tailscale] fetching tailscale auth key from Key Vault"
# `set +x` not strictly needed — we're not in -x — but we also avoid
# echoing the key. Capture into a variable scoped to this script's
# process; the variable dies when the script exits (cloud-init runs
# this via `runcmd:` which forks a fresh shell per command).
TAILSCALE_AUTH_KEY="$(
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$TAILSCALE_SECRET" \
    --query value -o tsv
)"

if [[ -z "$TAILSCALE_AUTH_KEY" || "$TAILSCALE_AUTH_KEY" == PLACEHOLDER* ]]; then
  echo "[01-tailscale] FATAL: tailscale auth key is empty or still the Terraform placeholder." >&2
  echo "[01-tailscale]   The operator must run \`az keyvault secret set\` before the final apply." >&2
  echo "[01-tailscale]   See specs/001-hardened-nemoclaw-deploy/quickstart.md §3." >&2
  exit 1
fi

echo "[01-tailscale] registering node on tailnet"
# --ssh=true enables Tailscale SSH (operator gets a shell without
# any inbound port + without us issuing SSH keys — FR-005 satisfied).
# --advertise-tags scopes the node under the operator's ACL.
# --hostname is deterministic so `tailscale ping <hostname>` works
# from any tailnet device.
tailscale up \
  --authkey="$TAILSCALE_AUTH_KEY" \
  --ssh=true \
  --advertise-tags="$TAILSCALE_TAG" \
  --hostname="$TAILSCALE_HOSTNAME" \
  --accept-dns=true

# Scrub the auth key from this process's memory. Bash `unset` does
# not zeroize the underlying memory page (the kernel may keep it in
# the heap until the page is reused), but the key is also bounded
# by Tailscale's 24h ephemeral expiry (R5) so the residual exposure
# window is short. The cloud-init log lines that reference this
# variable do not include the value (we never echoed it).
unset TAILSCALE_AUTH_KEY

# Belt-and-suspenders: scrub any line in cloud-init's persisted logs
# that might have captured the key value via a stray `set -x` or a
# script-error trace. This is paranoia — FR-012 requires we scrub.
for log in /var/log/cloud-init.log /var/log/cloud-init-output.log; do
  if [[ -f "$log" ]]; then
    sed -i -E 's/tskey-auth-[A-Za-z0-9-]+/tskey-auth-REDACTED/g' "$log"
  fi
done

echo "[01-tailscale] node registered. tailscale status:"
tailscale status || true
