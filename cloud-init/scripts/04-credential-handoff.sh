#!/usr/bin/env bash
# 04-credential-handoff.sh — cloud-init step that installs the
# credential-handoff binary plus the tmpfiles.d entry that creates
# /run/nemoclaw at boot.
#
# This script runs ONCE at cloud-init time. The binary it installs
# (/usr/local/bin/nemoclaw-credential-handoff) is what runs on EVERY
# nemoclaw.service start, as ExecStartPre with the systemd "+" prefix
# (see cloud-init/scripts/nemoclaw.service.tpl).
#
# Source-of-truth: contracts/credential-handoff.md
#
# Why ExecStartPre uses the "+" prefix:
#   - /run/nemoclaw is mode 0750 root:nemoclaw (per the tmpfiles.d
#     entry below). Group bits are r-x, NOT r-w-x — so the nemoclaw
#     user cannot create or unlink files inside the directory.
#   - The unit declares User=nemoclaw, so without "+" the handoff
#     would inherit that uid and `install`/`rm` would fail with
#     EACCES on the parent directory.
#   - The "+" prefix runs the named ExecStart* command with full
#     privileges, bypassing User=, Group=, ProtectSystem=,
#     ProtectHome=, ReadWritePaths=, and the rest of the unit's
#     sandbox. Main ExecStart= still runs as nemoclaw — only the
#     pre/post hooks are root.
#   - This keeps the dir's perms maximally restrictive (only root
#     writes; nemoclaw only reads via the 0400 owner-readable env
#     file once it's been chowned in).

set -euo pipefail

NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
NEMOCLAW_GROUP="${NEMOCLAW_GROUP:-nemoclaw}"

echo "[04-credential-handoff] writing tmpfiles.d entry for /run/nemoclaw"
cat > /etc/tmpfiles.d/nemoclaw.conf <<EOF
# Tmpfs subdirectory holding the transient EnvironmentFile that the
# credential handoff writes at NemoClaw service startup. Mode 0750
# means: only root + the nemoclaw group can list/traverse. The env
# file itself is mode 0400 owned by nemoclaw:nemoclaw — only nemoclaw
# can read it. The handoff binary that writes it runs as root via
# ExecStartPre=+; rm via ExecStartPost=+.
d /run/nemoclaw 0750 root ${NEMOCLAW_GROUP} -
EOF

# Materialise the directory immediately. systemd-tmpfiles is normally
# invoked by systemd at boot; we run it here so the nemoclaw service
# can start even on this same boot if cloud-init's runcmd ordering
# happens to land before the systemd-tmpfiles preset.
systemd-tmpfiles --create /etc/tmpfiles.d/nemoclaw.conf

echo "[04-credential-handoff] installing /usr/local/bin/nemoclaw-credential-handoff"
cat > /usr/local/bin/nemoclaw-credential-handoff <<'HANDOFF'
#!/usr/bin/env bash
# nemoclaw-credential-handoff — invoked by systemd as
# `ExecStartPre=+/usr/local/bin/nemoclaw-credential-handoff` for
# nemoclaw.service.
#
# Runs as root (ExecStartPre with "+" prefix bypasses User=nemoclaw
# and the unit's filesystem-protection sandbox).
#
# Fetches foundry-api-key from Key Vault via the VM's user-assigned
# managed identity, writes it to /run/nemoclaw/env (mode 0400 owned
# by nemoclaw:nemoclaw) so the unit's main ExecStart= process can
# consume it via EnvironmentFile=. Scrubs the in-process value
# before exit.
#
# Source-of-truth: contracts/credential-handoff.md
#
# Inputs (env vars set by the systemd unit's Environment= directives,
# templated by Terraform at apply time):
#   KV_NAME              Key Vault name
#   FOUNDRY_SECRET_NAME  Secret name (foundry-api-key)
#   OUT_FILE             Path of the tmpfs handoff file
#                        (/run/nemoclaw/env)
#
# Failure modes (each exits non-zero with a journald error; systemd
# then refuses to run ExecStart=, so the operator sees the failure
# in `systemctl status nemoclaw`):
#   - MI not assigned to VM      → az login --identity fails
#   - MI lacks Secrets-User RBAC → az returns 403
#   - Secret missing in KV       → az returns 404
#   - KV unreachable             → DNS/HTTP error
#   - /run/nemoclaw not writable → install(1) fails (cloud-init bug)

set -euo pipefail

: "${KV_NAME:?missing KV_NAME (set via systemd Environment=)}"
: "${FOUNDRY_SECRET_NAME:?missing FOUNDRY_SECRET_NAME (set via systemd Environment=)}"
: "${OUT_FILE:?missing OUT_FILE (set via systemd Environment=)}"

NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
NEMOCLAW_GROUP="${NEMOCLAW_GROUP:-nemoclaw}"

# 1. Authenticate via the VM's managed identity. Idempotent and fast
# (IMDS is a local hop, ~ms). Output silenced — `az` echoes the MI
# client_id and tenant_id which we don't want polluting journald.
az login --identity --output none

# 2. Fetch the secret. -o tsv keeps the value off any structured
# logger; we still avoid echoing $key anywhere.
key="$(
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$FOUNDRY_SECRET_NAME" \
    --query value -o tsv
)"

if [[ -z "$key" ]]; then
  echo "[credential-handoff] FATAL: secret value empty for $FOUNDRY_SECRET_NAME in $KV_NAME" >&2
  exit 1
fi

# Reject the deployment-time placeholder so systemd doesn't start
# NemoClaw with garbage credentials. The Terraform stanza for
# foundry-api-key writes "PLACEHOLDER-..." until the operator runs
# the documented `az keyvault secret set` step (quickstart.md §3).
if [[ "$key" == PLACEHOLDER* ]]; then
  echo "[credential-handoff] FATAL: $FOUNDRY_SECRET_NAME is still the Terraform placeholder." >&2
  echo "[credential-handoff]   Run \`az keyvault secret set --vault-name $KV_NAME --name $FOUNDRY_SECRET_NAME --value <real-key>\` per quickstart.md §3, then \`systemctl restart nemoclaw\`." >&2
  exit 1
fi

# 3. Write to tmpfs with strict perms.
#
# install(1) is the canonical atomic (create + chmod + chown) primitive
# on Linux. Source /dev/null so the new file starts empty; we stream
# the value into it in step 4. Running as root means -o nemoclaw
# -g nemoclaw is a real chown(2), not a no-op.
#
# umask 0277 belt-and-braces: even if -m were missing, the resulting
# mode would not exceed 0500 — but -m 0400 is authoritative.
umask 0277
install -m 0400 -o "$NEMOCLAW_USER" -g "$NEMOCLAW_GROUP" \
  /dev/null "$OUT_FILE"

# 4. Stream the value into the file. printf rather than echo so a
# leading dash or backslash in the key isn't interpreted as a flag
# or escape. The format `OPENAI_API_KEY=<value>\n` matches NemoClaw's
# documented environment-variable contract (the inference layer
# accepts the OpenAI-compatible key under that name even when the
# provider is Azure OpenAI / Foundry).
printf 'OPENAI_API_KEY=%s\n' "$key" > "$OUT_FILE"

# 5. Scrub the in-process value. unset(1) removes the variable name
# binding; the underlying bash heap page is reclaimed at script exit
# moments later. The kernel may keep that page until reuse, but the
# residual exposure window is bounded by the script's own lifetime
# (sub-second).
unset key

echo "[credential-handoff] wrote $OUT_FILE (mode 0400 owner $NEMOCLAW_USER:$NEMOCLAW_GROUP)"
HANDOFF
chmod 0755 /usr/local/bin/nemoclaw-credential-handoff
chown root:root /usr/local/bin/nemoclaw-credential-handoff

echo "[04-credential-handoff] handoff binary installed"
