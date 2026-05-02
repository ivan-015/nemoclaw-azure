#!/usr/bin/env bash
# 06-relight.sh — boot-time re-priming of NemoClaw.
#
# Why this script exists: 05-nemoclaw.sh deliberately does NOT
# persist COMPATIBLE_API_KEY to disk (security choice — see the
# comment block in 05-nemoclaw.sh near the runner script). OpenShell
# holds the live key in container memory. When the VM deallocates
# (auto-shutdown) and starts back up, the openshell-cluster container
# restarts with empty inference credentials: channel config persists
# (so `channels list` still shows telegram enabled) but the bridge
# can't actually call Foundry, and messages to the bot get silently
# dropped.
#
# The fix: at every boot, re-fetch foundry-api-key from Key Vault
# via the VM's managed identity and run `nemoclaw <name> rebuild`,
# which re-primes OpenShell's in-memory credentials and restarts
# channel sidecars. This keeps the "key never on disk" property
# from 05-nemoclaw.sh — the key transits stdin and is unset after.
#
# Inputs (from /etc/default/nemoclaw-relight, written by cloud-init):
#   KV_NAME                Key Vault holding foundry-api-key.
#   FOUNDRY_SECRET_NAME    Secret name (default: foundry-api-key).
#   NEMOCLAW_OPERATOR_USER Operator user (default: azureuser).
#   NEMOCLAW_SANDBOX_NAME  Sandbox name (default: nemoclaw).
#   TAILSCALE_SECRET       Tailscale auth-key secret name (default:
#                          tailscale-auth-key). Optional — if the
#                          secret is absent or empty, Tailscale re-auth
#                          is skipped (operator's choice to manage
#                          tailnet membership manually).
#   TAILSCALE_TAG          Advertised tag (default: tag:nemoclaw).
#   TAILSCALE_HOSTNAME     Tailnet hostname (default: nemoclaw-${suffix}
#                          via /etc/hostname).
#
# Why Tailscale re-auth lives here: tailscale auth keys can expire
# (24h ephemeral) or the node can be removed from the tailnet during
# a long deallocation. When that happens, tailscaled boots in
# `Logged out` state, the operator loses SSH/webchat access, and
# the bot is only reachable via Telegram. Without this re-auth step,
# the only fix was a manual `tailscale up --auth-key=...` from
# Azure run-command. Now: idempotent, runs on every boot, no-ops
# when already connected.

set -euo pipefail

: "${KV_NAME:?missing KV_NAME}"
FOUNDRY_SECRET_NAME="${FOUNDRY_SECRET_NAME:-foundry-api-key}"
NEMOCLAW_OPERATOR_USER="${NEMOCLAW_OPERATOR_USER:-azureuser}"
NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-nemoclaw}"
TAILSCALE_SECRET="${TAILSCALE_SECRET:-tailscale-auth-key}"
TAILSCALE_TAG="${TAILSCALE_TAG:-tag:nemoclaw}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"

LOG=/var/log/nemoclaw-relight.log
exec >>"$LOG" 2>&1

echo
echo "=== relight at $(date -Iseconds) ==="

# 0. Tailscale re-auth (best-effort — never fails the relight).
#
# Idempotent: if `tailscale status` shows we're already a member of a
# tailnet (i.e. anything other than "Logged out"), we skip. Otherwise
# we fetch the current key from KV and call `tailscale up`. The same
# az login below covers the Foundry fetch too — we authenticate once.
echo "[relight] az login --identity"
az login --identity --output none

ts_state="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState","unknown"))' 2>/dev/null || echo unknown)"
echo "[relight] tailscale BackendState: $ts_state"

if [[ "$ts_state" != "Running" ]]; then
  echo "[relight] tailscale not Running — fetching $TAILSCALE_SECRET from KV"
  TS_KEY="$(
    az keyvault secret show \
      --vault-name "$KV_NAME" \
      --name "$TAILSCALE_SECRET" \
      --query value -o tsv 2>/dev/null || true
  )"

  if [[ -n "$TS_KEY" && "$TS_KEY" != PLACEHOLDER* ]]; then
    echo "[relight] tailscale up (advertise-tags=$TAILSCALE_TAG, hostname=$TAILSCALE_HOSTNAME)"
    if tailscale up \
         --auth-key="$TS_KEY" \
         --ssh=true \
         --advertise-tags="$TAILSCALE_TAG" \
         --hostname="$TAILSCALE_HOSTNAME" \
         --accept-dns=true; then
      echo "[relight] tailscale re-auth OK: $(tailscale ip -4 2>/dev/null || echo unknown)"
    else
      echo "[relight] WARN: tailscale up failed — continuing (Telegram still works without tailnet)" >&2
    fi
    unset TS_KEY
  else
    echo "[relight] WARN: $TAILSCALE_SECRET absent/placeholder — tailnet access requires manual reseed." >&2
  fi
else
  echo "[relight] tailscale already Running — skipping re-auth."
fi

# 1. Wait for the openshell-cluster container to come up healthy.
# Docker's restart policy brings it back at boot; we just need to
# wait for the healthcheck to flip to "healthy" before issuing the
# rebuild (which talks to it via the gateway).
CONTAINER="openshell-cluster-${NEMOCLAW_SANDBOX_NAME}"
for i in $(seq 1 24); do
  state="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
  if [[ "$state" == "healthy" ]]; then
    echo "[$i] $CONTAINER healthy"
    break
  fi
  if [[ "$i" -eq 24 ]]; then
    echo "FATAL: $CONTAINER not healthy after 120s (last state: $state)" >&2
    exit 1
  fi
  sleep 5
done

# 2. Re-fetch the Foundry key from Key Vault. (az login was done in
#    step 0 above; the MI token lasts longer than this script's wall time.)
echo "[relight] fetching $FOUNDRY_SECRET_NAME from $KV_NAME"
FOUNDRY_API_KEY="$(
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$FOUNDRY_SECRET_NAME" \
    --query value -o tsv
)"

if [[ -z "$FOUNDRY_API_KEY" || "$FOUNDRY_API_KEY" == PLACEHOLDER* ]]; then
  echo "FATAL: $FOUNDRY_SECRET_NAME is empty or placeholder" >&2
  exit 1
fi

# 3. Rebuild via a runner that reads the key from stdin (same pattern
# as 05-nemoclaw.sh — keeps the key out of argv and out of any
# script-on-disk for longer than necessary).
OPERATOR_HOME="$(getent passwd "$NEMOCLAW_OPERATOR_USER" | cut -d: -f6)"
RUNNER="$OPERATOR_HOME/.nemoclaw/relight-runner.sh"

install -d -m 0700 -o "$NEMOCLAW_OPERATOR_USER" -g "$NEMOCLAW_OPERATOR_USER" "$OPERATOR_HOME/.nemoclaw"
install -m 0500 -o "$NEMOCLAW_OPERATOR_USER" -g "$NEMOCLAW_OPERATOR_USER" /dev/null "$RUNNER"
cat > "$RUNNER" <<RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail
read -r COMPATIBLE_API_KEY
export COMPATIBLE_API_KEY
nemoclaw $NEMOCLAW_SANDBOX_NAME rebuild --yes 2>&1
RUNNER_EOF
chown "$NEMOCLAW_OPERATOR_USER:$NEMOCLAW_OPERATOR_USER" "$RUNNER"

echo "[relight] running rebuild as $NEMOCLAW_OPERATOR_USER"
if printf '%s\n' "$FOUNDRY_API_KEY" | runuser -l "$NEMOCLAW_OPERATOR_USER" -- "$RUNNER"; then
  echo "[relight] rebuild succeeded"
else
  rc=$?
  echo "FATAL: rebuild failed (exit $rc) — see above" >&2
  unset FOUNDRY_API_KEY
  rm -f "$RUNNER"
  exit "$rc"
fi

unset FOUNDRY_API_KEY
rm -f "$RUNNER"

# 4. Start the OpenClaw-managed browser so the agent's `browser` tool
# is ready for live web navigation. `openclaw` is the in-sandbox CLI;
# the host invocation goes via `openshell sandbox exec --no-tty`.
# Idempotent: a no-op if the profile is already running. Non-fatal —
# inference works without it, only the browser tool degrades.
echo "[relight] starting openclaw browser inside sandbox $NEMOCLAW_SANDBOX_NAME"
# Use sudo -iu instead of runuser -l + bash -c (the latter chokes on
# the script-via-bash-c invocation pattern with "cannot execute
# binary file"; sudo -iu sets up a real login env and forwards the
# command string cleanly).
if ! sudo -iu "$NEMOCLAW_OPERATOR_USER" \
     openshell sandbox exec -n "$NEMOCLAW_SANDBOX_NAME" --no-tty -- openclaw browser start 2>&1; then
  echo "WARN: openclaw browser start failed — agent will fall back to web_search/web_fetch tools." >&2
fi

# 5. Smoke test.
echo "[relight] sandbox status:"
sudo -iu "$NEMOCLAW_OPERATOR_USER" nemoclaw "$NEMOCLAW_SANDBOX_NAME" status 2>&1 | head -10 || true

echo "=== relight complete at $(date -Iseconds) ==="
