[Unit]
Description=NemoClaw inference gateway
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=notify
User=nemoclaw
Group=nemoclaw

# ─── Environment (templated by Terraform at apply time) ──────────────
#
# `$${kv_name}` and `$${foundry_*}` are substituted by templatefile()
# in terraform/root/modules/vm/main.tf. The credential-handoff
# binary reads KV_NAME / FOUNDRY_SECRET_NAME / OUT_FILE; NemoClaw
# itself reads FOUNDRY_ENDPOINT / FOUNDRY_API_VERSION (and
# OPENAI_API_KEY, which arrives via EnvironmentFile= below — never
# in this Environment= block, never on disk in /etc/nemoclaw).
Environment=KV_NAME=${kv_name}
Environment=FOUNDRY_SECRET_NAME=foundry-api-key
Environment=OUT_FILE=/run/nemoclaw/env
Environment=FOUNDRY_ENDPOINT=${foundry_endpoint}
Environment=FOUNDRY_API_VERSION=${foundry_api_version}

# ─── Credential handoff (US2 / T033) ────────────────────────────────
#
# Source-of-truth: contracts/credential-handoff.md
#
# The "+" prefix runs the named command with full privileges,
# bypassing User=nemoclaw and the filesystem-protection sandbox
# (ProtectSystem=, ProtectHome=, ReadWritePaths=, etc.). Required
# because:
#
#   1. /run/nemoclaw is mode 0750 root:nemoclaw (per the tmpfiles.d
#      entry in 04-credential-handoff.sh). Group bits are r-x — only
#      root can create or unlink files inside it.
#   2. install(1) needs to chown the resulting env file to
#      nemoclaw:nemoclaw, and chown(2) requires CAP_CHOWN.
#   3. `az login --identity` writes its token cache under /root/.azure;
#      ProtectHome=true would otherwise hide /root from this command.
#
# Net effect: only the privileged hook touches the secret value; the
# main NemoClaw process inherits OPENAI_API_KEY via EnvironmentFile=
# read by systemd PID 1 (always root). NemoClaw itself runs as
# nemoclaw with the full sandbox applied.
ExecStartPre=+/usr/local/bin/nemoclaw-credential-handoff

# systemd reads this file as root (PID 1) before forking the main
# ExecStart= process; the env vars are baked into the child's
# initial environ and the file is no longer needed afterwards.
EnvironmentFile=/run/nemoclaw/env

ExecStart=/usr/local/bin/nemoclaw serve --config /etc/nemoclaw/config.yaml

# "+" again — same dir-permissions reason as ExecStartPre. Runs after
# ExecStart= reaches "active" (Type=notify), i.e. after NemoClaw has
# read OPENAI_API_KEY from its inherited environ. The kernel keeps
# the open inode for NemoClaw's already-set env, but the file path
# is gone so nothing else on the system can re-read the value.
ExecStartPost=+/bin/rm -f /run/nemoclaw/env

# ─── Hardening ───────────────────────────────────────────────────────
#
# Constitution Principle I: preserve NemoClaw's own sandbox posture,
# don't loosen it. These directives apply to the main ExecStart=
# process; the "+"-prefixed hooks above are deliberately exempt.
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/run/nemoclaw /var/lib/nemoclaw

# ─── Reliability ─────────────────────────────────────────────────────
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
