#!/usr/bin/env bash
# 04-credential-handoff.sh — install the credential handoff binary
# and the tmpfiles.d entry that creates /run/nemoclaw at boot.
#
# AT US1: this script writes a stub `/usr/local/bin/nemoclaw-credential-
# handoff` that exits 0 without doing anything. The systemd unit's
# ExecStartPre at US1 is `/bin/true` (placeholder), so the stub is not
# even invoked. The stub exists so the path is stable and US2's
# overwrite is non-disruptive.
#
# AT US2 (T032): this script is replaced with the real implementation
# that fetches `foundry-api-key` from Key Vault via the VM's managed
# identity and writes it to /run/nemoclaw/env (mode 0400, owned by
# the nemoclaw user) per contracts/credential-handoff.md.
#
# Inputs (US2 only):
#   KV_NAME              Key Vault name (passed by the systemd unit's
#                        Environment= directive — US2)
#   FOUNDRY_SECRET_NAME  Secret name (default: foundry-api-key — US2)
#   OUT_FILE             Path of the tmpfs file (default
#                        /run/nemoclaw/env — US2)

set -euo pipefail

NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
NEMOCLAW_GROUP="${NEMOCLAW_GROUP:-nemoclaw}"

echo "[04-credential-handoff] writing tmpfiles.d entry for /run/nemoclaw"
cat > /etc/tmpfiles.d/nemoclaw.conf <<EOF
# Tmpfs subdirectory holding the transient EnvironmentFile that the
# credential handoff writes at NemoClaw service startup. Mode 0750
# means: only root + the nemoclaw group can list. The env file
# itself is mode 0400 owned by nemoclaw:nemoclaw.
d /run/nemoclaw 0750 root ${NEMOCLAW_GROUP} -
EOF

# Materialise the directory immediately (systemd-tmpfiles is
# normally invoked by systemd at boot; manually create now so the
# nemoclaw service can start even if cloud-init runs after the
# tmpfiles preset).
systemd-tmpfiles --create /etc/tmpfiles.d/nemoclaw.conf

echo "[04-credential-handoff] writing US1 stub binary"
cat > /usr/local/bin/nemoclaw-credential-handoff <<'STUB'
#!/usr/bin/env bash
# US1 stub. US2 (T032) replaces this with the real credential handoff.
# At US1 the systemd unit's ExecStartPre is /bin/true so this is not
# actually invoked; the file exists only to reserve the path.
echo "[credential-handoff] US1 stub — replaced in US2 (T032)" >&2
exit 0
STUB
chmod 0755 /usr/local/bin/nemoclaw-credential-handoff
chown root:root /usr/local/bin/nemoclaw-credential-handoff

echo "[04-credential-handoff] stub installed"
