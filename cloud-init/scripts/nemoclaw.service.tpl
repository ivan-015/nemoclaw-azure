[Unit]
Description=NemoClaw inference gateway
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=notify
User=nemoclaw
Group=nemoclaw

# US1 placeholder: the credential handoff is wired in US2 (T033).
# At US1 the unit is enabled but NOT started — there is no Foundry
# API key in its environ, so starting it would crash NemoClaw with
# a missing-credential error and pollute the journal. The acceptance
# test for US1 is `nemoclaw doctor` from a Tailscale shell, not a
# running service.
#
# US2 replaces this block with:
#   Environment=KV_NAME=${kv_name}
#   Environment=FOUNDRY_SECRET_NAME=foundry-api-key
#   Environment=OUT_FILE=/run/nemoclaw/env
#   Environment=FOUNDRY_ENDPOINT=${foundry_endpoint}
#   Environment=FOUNDRY_API_VERSION=${foundry_api_version}
#   ExecStartPre=/usr/local/bin/nemoclaw-credential-handoff
#   EnvironmentFile=/run/nemoclaw/env
#   ExecStart=/usr/local/bin/nemoclaw serve --config /etc/nemoclaw/config.yaml
#   ExecStartPost=/bin/rm -f /run/nemoclaw/env
ExecStartPre=/bin/true
ExecStart=/usr/local/bin/nemoclaw serve --config /etc/nemoclaw/config.yaml

# Hardening (constitution Principle I — preserve NemoClaw's own
# sandbox posture, don't loosen it).
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/run/nemoclaw /var/lib/nemoclaw

# Reliability
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
