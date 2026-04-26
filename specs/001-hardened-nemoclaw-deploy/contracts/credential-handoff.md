# Contract: Credential Handoff (systemd `ExecStartPre` + tmpfs + `EnvironmentFile=`)

**Plan**: [../plan.md](../plan.md)
**Date**: 2026-04-25 (replaces the obsolete `broker-uds.md` per spec
clarification Q4)

This contract describes how the Foundry API key reaches NemoClaw's host
process at startup. It is **explicitly named** in constitution
Principle II as a permitted mediation channel:

> "...surfaced to NemoClaw only through a mediated channel (e.g. a
> local broker on a Unix domain socket; **a just-in-time tmpfs file
> with restrictive permissions deleted after use**)."

## Components

### 1. The `nemoclaw-credential-handoff` script

- **Path**: `/usr/local/bin/nemoclaw-credential-handoff`
- **Owner / mode**: `root:root`, `0755`
- **Installed by**: cloud-init `04-credential-handoff.sh` (write_files +
  chmod)
- **Executed by**: systemd, as `ExecStartPre=` for `nemoclaw.service`,
  as the unit's `User=nemoclaw`

**Script contract** (pseudocode; the real script ships in
`cloud-init/scripts/04-credential-handoff.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Inputs (env vars set by the systemd unit's Environment= directives,
# templated by Terraform):
: "${KV_NAME:?missing KV_NAME}"
: "${FOUNDRY_SECRET_NAME:?missing FOUNDRY_SECRET_NAME}"
: "${OUT_FILE:?missing OUT_FILE}"   # /run/nemoclaw/env

# 1. Authenticate via VM managed identity (idempotent, fast).
az login --identity --output none

# 2. Fetch the secret. Don't echo it.
key=$(az keyvault secret show \
  --vault-name "$KV_NAME" \
  --name "$FOUNDRY_SECRET_NAME" \
  --query value -o tsv)

# 3. Write to tmpfs with strict perms. install(1) is atomic.
umask 0277
install -m 0400 -o nemoclaw -g nemoclaw /dev/null "$OUT_FILE"
printf 'OPENAI_API_KEY=%s\n' "$key" > "$OUT_FILE"

# 4. Scrub.
unset key
```

**Failure modes** (all exit non-zero with a journald error):

- Managed identity not assigned to VM → `az login --identity` fails.
- VM MI lacks `Key Vault Secrets User` RBAC → `az keyvault secret show`
  returns 403.
- Secret not found in KV → `az` returns 404.
- KV unreachable (network ACL misconfigured, MI token expired) → DNS
  or HTTP error.
- `/run/nemoclaw/` not writable → `install` fails.

systemd handles failure by not starting the main `ExecStart=`. The
operator sees the failure in `systemctl status nemoclaw` and
`journalctl -u nemoclaw`.

### 2. The `/run/nemoclaw/env` tmpfs file

- **Filesystem**: tmpfs (RAM-backed, never on disk).
- **Mount**: `/run/nemoclaw` is a mode-0750 tmpfs subdirectory of `/run`
  (which is itself tmpfs on systemd-managed Linux). Created by
  `cloud-init` with `tmpfiles.d` entry:
  ```
  d /run/nemoclaw 0750 root nemoclaw -
  ```
- **Owner / mode of `env`**: `nemoclaw:nemoclaw`, `0400` — only the
  nemoclaw user can read it.
- **Lifetime**: between `ExecStartPre` (writes) and `ExecStartPost`
  (deletes). Typically < 1 second.
- **Format**: a single line `OPENAI_API_KEY=<value>\n`. Multiple
  variables permitted in future if NemoClaw adds another credential.

### 3. The systemd unit

- **Path**: `/etc/systemd/system/nemoclaw.service`
- **Templated by**: Terraform via `cloud-init/scripts/nemoclaw.service.tpl`
- **Required directives**:

```ini
[Unit]
Description=NemoClaw inference gateway
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=notify
User=nemoclaw
Group=nemoclaw

# Templated Terraform vars:
Environment=KV_NAME=${kv_name}
Environment=FOUNDRY_SECRET_NAME=foundry-api-key
Environment=OUT_FILE=/run/nemoclaw/env
Environment=FOUNDRY_ENDPOINT=${foundry_endpoint}
Environment=FOUNDRY_API_VERSION=${foundry_api_version}

ExecStartPre=/usr/local/bin/nemoclaw-credential-handoff
EnvironmentFile=/run/nemoclaw/env
ExecStart=/usr/local/bin/openshell --some-args ...
ExecStartPost=/bin/rm -f /run/nemoclaw/env

# Hardening
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
```

**Note on `EnvironmentFile=`**: systemd reads it *before* running
`ExecStart=`. The variables become part of `ExecStart`'s environment.
This is exactly what we want for NemoClaw's documented contract
("set OPENAI_API_KEY").

**Note on `ExecStartPost=`**: this runs *after* `ExecStart=` has
started and entered "active" state. The tmpfs file is unlinked
**after** NemoClaw has read it. The kernel keeps an open inode for
NemoClaw's already-set env, but the file path is gone — nothing else
on the system can re-read the value.

## Audit trail

Every Key Vault `SecretGet` operation by the VM's managed identity is
recorded in Azure's diagnostic logs and shipped to Log Analytics.
That's the audit. There's no custom journald emitter; Azure's audit
*is* the audit.

KQL example query (one record per NemoClaw service start):

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| where identity_claim_oid_g == "<vm-mi-principal-id>"
| project TimeGenerated, requestUri_s, ResultSignature
```

## Verification (mapped to spec)

- **FR-007** (fetch from KV via MI at service start) → verified by:
  unit's `ExecStartPre=` runs `nemoclaw-credential-handoff`; script
  uses `az login --identity`.
- **FR-008** (tmpfs file mode 0400, unlinked before steady state) →
  verified by: `install -m 0400`, tmpfs mount, `ExecStartPost=rm`.
- **FR-009** (sandboxed agent never sees the key) → verified by spec
  SC-004 tooth-check: `grep` agent's `/proc/<pid>/environ` for KV
  value returns zero matches.
- **FR-010** (audit landing) → verified by spec SC-008: KQL query
  returns the `SecretGet` event within 5 min of NemoClaw start.

## What this contract is NOT

- **Not a runtime broker**: there is no UDS, no peer-cred auth, no
  request/response protocol. Keys flow once at service start.
- **Not a cache**: NemoClaw's host process holds the key in its
  environ for the lifetime of the process. Rotation requires
  `systemctl restart nemoclaw`.
- **Not a deny-list enforcement point**: the only secret this script
  fetches is `foundry-api-key`. Any expansion requires a spec
  amendment.

## Failure-mode coverage matrix

| Scenario | Expected behaviour |
|---|---|
| KV unreachable | `ExecStartPre` fails → service doesn't start → operator sees `systemctl status nemoclaw` red → recovers via Run Command + `az` to diagnose |
| Foundry secret missing | `ExecStartPre` fails with 404 → as above |
| MI lacks RBAC | `ExecStartPre` fails with 403 → terraform misconfig, fix and re-apply |
| Tmpfs mount missing | `install` fails → cloud-init misconfig — `tmpfiles.d` entry should have created it |
| `nemoclaw` user absent | `chown` in `install` fails → cloud-init must create the user before installing the unit |
| Service crashes mid-flight | systemd restarts (Restart=on-failure); fresh credential fetch on next start. Old environ is gone with the previous process. |
| Foundry key rotated in KV | Operator runs `systemctl restart nemoclaw` → next startup fetches the new key. No code change. |
