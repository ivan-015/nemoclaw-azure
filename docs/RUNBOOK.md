# Operator Runbook

Triage guide for when something doesn't work. Order is rough order of
likelihood, not order of severity. **Each entry has: symptom → 30-
second diagnostic → fix.**

If you hit something not in this list, fix it once, then add it here
so the next time takes 5 minutes instead of 2 hours.

---

## Quick reference

| Resource | Value |
|---|---|
| VM | `vm-nemoclaw-p02f` in `RG-NEMOCLAW`, centralus |
| Tailscale hostname | `nemoclaw-p02f-1` (note the `-1` suffix from a prior re-deploy) |
| Key Vault | `kv-nc-p02f` (secrets: `foundry-api-key`, `tailscale-auth-key`, `telegram-bot-token`) |
| Sandbox name | `nemoclaw` |
| Auto-shutdown | 21:00 PT daily |
| Auto-start | 08:00 PT daily (Automation Account `auto-nemoclaw-p02f`) |
| Operator user | `azureuser` |

The first column of every CLI command below assumes you've run
`tailscale up` on your laptop and `nemoclaw-p02f-1` resolves.

---

## 1. Bot received my message but never replied

**Symptom:** Telegram delivers your message (single check mark turns
to two) but no reply comes back.

**30-second diagnostic** — from your laptop:

```bash
ssh azureuser@nemoclaw-p02f-1 'nemoclaw nemoclaw status; nemoclaw nemoclaw logs | tail -30'
```

Look for:
- `Inference: not probed (Endpoint URL is not known...)` → harmless
  (just a status-check skip). Not the bug.
- `Connected: no` and no recent log lines → bridge isn't running,
  see §2.
- `provider credential not found` in any rebuild logs → the Foundry
  key is missing from OpenShell's memory. **Most common cause after a
  VM restart.**

**Fix (most common case — Foundry key dropped):**

```bash
ssh azureuser@nemoclaw-p02f-1
sudo bash -c 'az login --identity --output none && KEY=$(az keyvault secret show --vault-name kv-nc-p02f --name foundry-api-key --query value -o tsv) && sudo -iu azureuser COMPATIBLE_API_KEY="$KEY" nemoclaw nemoclaw rebuild --yes'
```

After ~90s, send another Telegram message. If still dead, see §2.

**Why this happens:** `cloud-init/scripts/05-nemoclaw.sh` deliberately
doesn't write the Foundry key to disk (security choice — see comments
in that file). OpenShell holds it in container memory only. When the
openshell-cluster container restarts, the key is gone. **The
boot-time `nemoclaw-relight.service` (cloud-init/scripts/06-relight.sh)
should fix this automatically on every boot.** If it's not running,
check `journalctl -u nemoclaw-relight.service` and `/var/log/nemoclaw-relight.log`.

**Heads-up:** the relight unit's `TimeoutStartSec` must be **≥ 900s**
because `nemoclaw rebuild` re-uploads a ~2.4 GB sandbox image into
the OpenShell gateway, which routinely takes 5-7 min on a Standard_E2as_v5.
Earlier versions of this repo set it to 300s and the unit got SIGTERM-ed
mid-rebuild, leaving the sandbox in a half-restored state. Verify with:
```bash
ssh azureuser@nemoclaw-p02f \
  'grep TimeoutStartSec /etc/systemd/system/nemoclaw-relight.service'
```
If it shows `300`, edit the unit (`sudo systemctl edit --full nemoclaw-relight.service`)
and set `TimeoutStartSec=900`, then `sudo systemctl daemon-reload`.

---

## 2. Telegram bridge is dead even after re-priming

**Symptom:** §1 fix didn't help. Bot still silent.

**30-second diagnostic:**

```bash
ssh azureuser@nemoclaw-p02f-1 \
  "docker exec openshell-cluster-nemoclaw sh -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A'"
```

You should see a `nemoclaw` pod in the `openshell` namespace. If
you don't, the rebuild dropped it without recreating.

**Fix — full channel re-add with token from KV:**

```bash
ssh azureuser@nemoclaw-p02f-1
sudo bash <<'EOF'
az login --identity --output none
FOUNDRY_KEY=$(az keyvault secret show --vault-name kv-nc-p02f --name foundry-api-key --query value -o tsv)
TG_TOKEN=$(az keyvault secret show --vault-name kv-nc-p02f --name telegram-bot-token --query value -o tsv)
RUNNER=$(mktemp)
chmod 0500 "$RUNNER"
chown azureuser:azureuser "$RUNNER"
cat > "$RUNNER" <<'INNER'
#!/bin/bash
set +e
read -r COMPATIBLE_API_KEY
read -r TG_TOKEN
export COMPATIBLE_API_KEY
printf 'Y\n' | nemoclaw nemoclaw channels remove telegram
printf '%s\nY\n' "$TG_TOKEN" | nemoclaw nemoclaw channels add telegram
nemoclaw nemoclaw rebuild --yes
INNER
printf '%s\n%s\n' "$FOUNDRY_KEY" "$TG_TOKEN" | runuser -l azureuser -- "$RUNNER"
rm -f "$RUNNER"
EOF
```

---

## 3. Bot replies "OpenClaw: access not configured. Pairing code: XXXXXXXX"

**Symptom:** Bot is alive, but every Telegram user gets a "pairing
required" message instead of a real reply.

**Why:** OpenClaw's security model — every Telegram user must be
explicitly approved by the operator before the bot will talk to them.
Pairing codes are short-lived (a few minutes).

**Fix:**

1. **Send a fresh message to the bot** (the current pairing code in
   the message you have is probably already expired).
2. Copy the new pairing code from the bot's reply.
3. SSH in and connect to the sandbox:
   ```bash
   ssh azureuser@nemoclaw-p02f-1
   nemoclaw nemoclaw connect
   ```
4. Inside the sandbox:
   ```bash
   openclaw pairing approve telegram <NEW_CODE>
   ```
5. Exit (Ctrl+D), send another Telegram message — bot should now
   reply for real.

Once approved, the pairing persists for that Telegram user — they
don't need re-approval on future restarts (unless `channels remove`
is run, which wipes pairings).

---

## 3b. `tailscale status` shows the VM is missing / SSH fails after auto-shutdown

**Symptom:** Morning after auto-shutdown+restart. `tailscale status`
on your laptop doesn't list `nemoclaw-p02f`. SSH fails with
"could not resolve hostname". Telegram bot still works (it doesn't
need Tailscale).

**Why:** Tailscale auth keys can expire (24h ephemeral by default
when first issued, longer if you regenerate as **Reusable + 90-day**),
and an ephemeral node that was offline for >X hours gets removed
from the tailnet by the coordination server. On boot, `tailscaled`
starts but goes to `BackendState=NeedsLogin` ("Logged out") because
the persisted state lost its auth context. **Without re-auth, the
node stays off the tailnet forever.**

**Fix (now built into the relight unit — runs at every boot):**
The updated `06-relight.sh` includes a step 0 that:
1. Checks `tailscale status --json` for `BackendState=Running`.
2. If not Running, fetches `tailscale-auth-key` from KV and runs
   `tailscale up --auth-key=... --advertise-tags=tag:nemoclaw
   --hostname=<computer_name>`.
3. If the secret is absent or stale, logs a WARN and continues
   (Telegram still works — just no SSH/webchat).

**If you're on an old VM where the relight unit isn't installed
yet, see "One-time: install the relight unit" below.**

**Manual emergency fix when even the relight is broken:**

```bash
# 1. Generate a Reusable + 90-day key at
#    https://login.tailscale.com/admin/settings/keys (tag: nemoclaw)
# 2. Reseed it:
az keyvault secret set --vault-name kv-nc-p02f --name tailscale-auth-key --value 'tskey-auth-...'
# 3. Force a re-auth via run-command:
az vm run-command invoke -g rg-nemoclaw -n vm-nemoclaw-p02f --command-id RunShellScript --scripts \
  'KEY=$(az keyvault secret show --vault-name kv-nc-p02f --name tailscale-auth-key --query value -o tsv); \
   tailscale up --auth-key="$KEY" --ssh=true --advertise-tags=tag:nemoclaw \
                --hostname=nemoclaw-p02f --accept-dns=true'
```

The VM should appear in `tailscale status` within ~15s.

---

## 4. `ssh azureuser@nemoclaw-p02f` says "could not resolve hostname"

**Symptom:** SSH refuses to find the host.

**30-second diagnostic:**

```bash
tailscale status | grep nemoclaw
```

You'll likely see `nemoclaw-p02f-1` (with a `-1` or higher suffix).
Tailscale appends a numeric suffix when a previous registration
claimed the original name — common after a `terraform destroy +
apply` cycle.

**Fix:** Use the suffixed name:
```bash
ssh azureuser@nemoclaw-p02f-1
```

Or clean it up permanently in https://login.tailscale.com/admin/machines:
delete the stale entry, rename the active one back to `nemoclaw-p02f`.

---

## 5. `az vm run-command invoke` returns Conflict / hangs

**Symptom:** Trying to run anything via Run Command, you get
`(Conflict) Run command extension execution is in progress.`

**Why:** Azure Run Command serializes — only one invocation per VM
at a time. A previous (possibly orphaned) call hasn't released the
lock.

**Fix:** wait a minute, then retry. Or just SSH in over Tailscale —
Run Command is a fallback path; SSH is the primary.

---

## 6. VM didn't auto-start at 08:00 PT

**Symptom:** Morning, you go to use the bot, VM is still deallocated.

**30-second diagnostic:**

```bash
az vm list -d -g RG-NEMOCLAW --query "[?name=='vm-nemoclaw-p02f'].powerState" -o tsv
az automation runbook list-by-automation-account \
  --automation-account-name auto-nemoclaw-p02f \
  --resource-group RG-NEMOCLAW \
  --query "[].{name:name, lastModifiedTime:lastModifiedTime}" -o table
```

Then look at recent runbook job runs:
```bash
az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/RG-NEMOCLAW/providers/Microsoft.Automation/automationAccounts/auto-nemoclaw-p02f/jobs?api-version=2017-05-15-preview&\$top=5"
```

**Fix:** Wake manually:
```bash
az vm start -g RG-NEMOCLAW -n vm-nemoclaw-p02f
```

Then check the runbook for errors — common ones:
- The runbook MI lost its role assignment (re-`terraform apply`).
- Az.Compute / Az.Accounts modules dropped from the Automation
  Account (re-import via `az automation module create` or via the
  portal).

---

## 7. `terraform apply` fails on `azurerm_automation_schedule.daily_start`

**Symptom:** `start_time must be at least 5 minutes in the future`
or similar.

**Why:** The module computes `start_time` from `timestamp()` + 26h.
If you're applying in a tight loop or the clock skews, you can land
just outside the window.

**Fix:** Re-run `terraform apply`. The lifecycle's
`ignore_changes = [start_time]` means a successful create sticks; a
failed create regenerates the timestamp on retry.

If it persistently fails, override in tfvars by setting
`auto_start_enabled = false`, applying, then flipping back to `true`
in a separate apply.

---

## 8. `nemoclaw nemoclaw status` shows "Endpoint URL is not known"

**Not actually a bug.** This is a misleading status-check skip.
The Foundry endpoint URL lives in OpenShell's gateway config (visible
via `openshell inference get -g nemoclaw`) but `nemoclaw status`
doesn't introspect that — it only reads the local sandbox config,
which doesn't store the URL.

**Ignore this line.** Bot health is determined by whether messages
get replies, not by this status field.

---

## 9. Swapping the inference model

The model is **not** stored in `onboard-session.json` — editing
that field and rebuilding does nothing because resume mode reads a
cached `provider_selection` / `inference` step state. The real switch
is a single `openshell` command and takes ~1 second:

```bash
ssh azureuser@nemoclaw-p02f \
  'sudo -iu azureuser openshell inference set \
     -g nemoclaw \
     --model <DEPLOYMENT_NAME> \
     --provider compatible-endpoint'
```

`<DEPLOYMENT_NAME>` is the Azure AI Foundry deployment name (e.g.
`epl-gpt-4o`, `gpt-5.4`). The command validates the endpoint at
swap time, so a bad name fails fast — no rebuild, no downtime.

Verify with `nemoclaw nemoclaw status` (the `Model:` line updates
immediately). No restart of the sandbox is needed; the next
inference call picks up the new route.

**Do not** run `nemoclaw nemoclaw rebuild --yes` to change models.
Rebuild destroys the sandbox before recreating it; if anything in
the recreate path fails (Brave revalidation, image build, etc.) you
end up with no sandbox at all — see §10.

---

## 10. Recovering when `nemoclaw rebuild` aborts mid-recreate

If `nemoclaw rebuild` prints `Recreate failed after sandbox was
destroyed`, the sandbox is **gone** and a plain rerun won't bring
it back. The recovery path is `nemoclaw onboard --non-interactive
--resume` with **all three KV secrets piped via stdin**, not just
`COMPATIBLE_API_KEY`:

```bash
ssh azureuser@nemoclaw-p02f "sudo bash -c '
  set -e
  az login --identity --output none
  FOUNDRY=\$(az keyvault secret show --vault-name kv-nc-p02f --name foundry-api-key --query value -o tsv)
  BRAVE=\$(az keyvault secret show --vault-name kv-nc-p02f --name brave-search-api --query value -o tsv)
  TELEGRAM=\$(az keyvault secret show --vault-name kv-nc-p02f --name telegram-bot-token --query value -o tsv)
  printf \"%s\n%s\n%s\n\" \"\$FOUNDRY\" \"\$BRAVE\" \"\$TELEGRAM\" | \
    sudo -iu azureuser \
      COMPATIBLE_API_KEY=\"\$FOUNDRY\" \
      BRAVE_API_KEY=\"\$BRAVE\" \
      TELEGRAM_BOT_TOKEN=\"\$TELEGRAM\" \
      nemoclaw onboard --non-interactive --resume \
        2>&1 | tee /var/log/nemoclaw-recover.log | tail -120
'"
```

**Why each piece matters:**
- `--non-interactive` skips the messaging-channel toggle UI which
  would otherwise consume the rest of stdin as keystrokes and hang
  on the Telegram-User-ID prompt.
- The 3-line stdin matches `nemoclaw-relight.sh:83` exactly: foundry,
  brave, telegram — in that order. Resume mode revalidates at
  least Brave even if telegram is already cached.
- All three env vars must be set as well — onboard reads from the
  env when stdin is empty, and the relight uses `--no-wait`-style
  fallthrough.

After the sandbox comes back up the workspace PVC has a new UUID,
so re-run the composio restore (next section) and verify with
`nemoclaw nemoclaw status`. The model swap from §9 must be
re-applied if it wasn't already in effect when rebuild ran — resume
mode restores the cached model, not whatever you tried to switch to.

---

## Common diagnostic commands

```bash
# Sandbox health
ssh azureuser@nemoclaw-p02f-1 'nemoclaw nemoclaw status'

# Live gateway logs (Ctrl+C to exit)
ssh azureuser@nemoclaw-p02f-1 'nemoclaw nemoclaw logs --follow'

# Inside-the-cluster pod state
ssh azureuser@nemoclaw-p02f-1 \
  "docker exec openshell-cluster-nemoclaw sh -c \
   'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A'"

# Boot-time relight log (after the morning auto-start)
ssh azureuser@nemoclaw-p02f-1 'sudo cat /var/log/nemoclaw-relight.log'

# Systemd unit status for the relight
ssh azureuser@nemoclaw-p02f-1 'systemctl status nemoclaw-relight.service'

# Force a relight run by hand
ssh azureuser@nemoclaw-p02f-1 'sudo systemctl start nemoclaw-relight.service'
```

## One-time: install the relight unit on an already-deployed VM

The `nemoclaw-relight.service` systemd unit is provisioned by
cloud-init, which only runs on first boot. If your VM was deployed
**before** this code landed, the unit doesn't exist yet — install it
by hand without touching Terraform (which would otherwise want to
rebuild the VM and wipe state).

From your laptop, run this once:

```bash
SCRIPT_LOCAL=cloud-init/scripts/06-relight.sh
SCRIPT_REMOTE=/usr/local/sbin/nemoclaw-relight.sh

# 1. Copy the relight script to the VM via Tailscale SSH.
scp "$SCRIPT_LOCAL" azureuser@nemoclaw-p02f-1:/tmp/06-relight.sh

# 2. Install everything in one shot as root.
ssh azureuser@nemoclaw-p02f-1 'sudo bash -s' <<'REMOTE'
set -euo pipefail

install -m 0750 -o root -g root /tmp/06-relight.sh /usr/local/sbin/nemoclaw-relight.sh
rm -f /tmp/06-relight.sh

# Adjust KV_NAME / sandbox to match your deploy if you've customized them.
cat > /etc/default/nemoclaw-relight <<'ENVFILE'
KV_NAME=kv-nc-p02f
FOUNDRY_SECRET_NAME=foundry-api-key
NEMOCLAW_OPERATOR_USER=azureuser
NEMOCLAW_SANDBOX_NAME=nemoclaw
TAILSCALE_SECRET=tailscale-auth-key
TAILSCALE_TAG=tag:nemoclaw
TAILSCALE_HOSTNAME=nemoclaw-p02f
ENVFILE
chmod 0644 /etc/default/nemoclaw-relight

cat > /etc/systemd/system/nemoclaw-relight.service <<'UNIT'
[Unit]
Description=Re-prime NemoClaw inference + Tailscale credentials at boot
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
ConditionPathExists=/var/lib/cloud/instance/boot-finished

[Service]
Type=oneshot
EnvironmentFile=/etc/default/nemoclaw-relight
ExecStart=/usr/local/sbin/nemoclaw-relight.sh
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 /etc/systemd/system/nemoclaw-relight.service

systemctl daemon-reload
systemctl enable nemoclaw-relight.service
echo "Installed. Trigger now? Run: sudo systemctl start nemoclaw-relight.service"
REMOTE
```

Verify next boot picks it up:

```bash
ssh azureuser@nemoclaw-p02f-1 'systemctl is-enabled nemoclaw-relight.service'
# expected: enabled
```

Then `az vm deallocate` + `az vm start` to confirm the relight runs
end-to-end (check `/var/log/nemoclaw-relight.log`).

---

## One-time: install the Composio skill on an already-deployed VM

Composio gives the agent runtime access to ~1000 SaaS apps (Gmail,
Slack, GitHub, Notion, etc.) via per-tool OAuth at use-time —
**no credentials are pre-stored**. The agent asks Composio's tool
router for a tool, Composio prompts the operator with an OAuth link
on first use, the agent then executes.

NemoClaw stock does **not** ship Composio integration. There are
multiple plausible install paths — only one actually works on this
deploy. The recipe below is the path that worked; the dead ends are
documented so you don't waste time re-trying them.

### Working recipe (3 commands on the host)

```bash
ssh azureuser@nemoclaw-p02f-1

# 1. Install the Composio skill universally on the host. This pulls
#    https://github.com/composiohq/skills, lands at
#    ~/.agents/skills/composio with a SKILL.md + AGENTS.md + rules/.
npx -y skills add https://github.com/composiohq/skills --skill composio --yes

# 2. Deploy the skill INTO the running NemoClaw sandbox. This is the
#    NemoClaw-native way to bake a skill directory into the sandbox
#    image (it uploads all non-dot files in the directory).
nemoclaw nemoclaw skill install ~/.agents/skills/composio

# 3. Verify the agent sees it.
openshell sandbox exec -n nemoclaw --no-tty -- openclaw skills list | grep composio
# Expected: │ ✓ ready │ 📦 composio │ Use 1000+ external apps via Composio │ openclaw-managed │
```

After install, connect to the sandbox and start chatting — the agent
will prompt you for OAuth on first use of any Composio-backed tool.

```bash
nemoclaw nemoclaw connect
openclaw tui
# In the chat: "send myself an email via Gmail saying 'composio test'"
```

### Composio CLI login on the host (optional)

The host-side `~/.composio/composio` CLI binary persists creds at
`~/.composio/credentials.json`. **The skill route doesn't strictly
need this** — Composio's tool router handles auth at runtime — but if
you want CLI-side debugging tools (`composio whoami`, `composio
toolkits list`, etc.):

```bash
# Browser-based session login (no key required upfront)
~/.composio/composio login --no-wait
# Open the printed URL in your laptop browser, complete login.
# Composio's CLI auto-completes when you finish in the browser.

~/.composio/composio whoami
# Should show: Email: <you>@…, Default Org: <your-workspace>
```

### Dead ends (don't waste time on these)

The following all looked plausible but **do not work** on this
NemoClaw deploy:

1. **`composio login --user-api-key uak_...`** — the install prompt
   Composio's UI shows uses a `uak_` user API key. The composio.dev
   dashboard at `platform.composio.dev/settings` issues `ck_` keys
   instead, which Composio's API rejects with HTTP 401 against the
   `--user-api-key` flag. There is no `uak_` generation page in the
   dashboard as of this writing. **Use the browser-flow login above
   if you need the CLI logged in.**

2. **`openclaw mcp set composio <json>` from inside the sandbox** —
   prints `Saved MCP server "composio"` but the message is
   misleading: `/sandbox/.openclaw/openclaw.json` is a read-only
   bind mount inside the sandbox, and writes are silently dropped.
   The "saved" log line lies.

3. **`nemoclaw nemoclaw config set --key mcpServers.composio …`** —
   NemoClaw's config schema does **not** include an `mcpServers`
   slot. The CLI rejects with `Key validation failed: not a
   recognized openclaw config path`. Generic MCP server registration
   via host config is unsupported.

4. **`openclaw plugins install clawhub:composio`** — Composio is not
   distributed as an OpenClaw plugin in the OpenClaw marketplace.
   The `composio` plugin code only exists in the
   `ComposioHQ/openclaw-composio` fork, not in stock OpenClaw which
   is what NemoClaw bundles.

5. **`npx skills add … composio --yes` run *inside* the sandbox** —
   the universal install lands but the per-agent symlinks fail with
   `EACCES: permission denied, mkdir '/sandbox/.agents'` because
   `/sandbox/.agents/` is read-only inside the sandbox. **Run it on
   the host instead** (Step 1 above).

### Restoring Composio after a `nemoclaw rebuild` (binary + venv + creds get wiped)

A `nemoclaw rebuild` recreates the sandbox PVC under a new UUID and
copies back only the directories listed in the rebuild manifest
(`agents/`, `skills/`, `workspace/`, `credentials/`, etc.). It does
**not** preserve the host-injected files we put at `/sandbox/composio`,
`/sandbox/.composio/`, `/sandbox/.local/bin/composio`, or
`/sandbox/.venv-composio/`. After every rebuild — including any
recovery via §10 — run this from your laptop:

```bash
ssh azureuser@nemoclaw-p02f 'sudo bash -s' <<'REMOTE'
set -uo pipefail
PVC=$(ls -d /var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/storage/pvc-*_openshell_workspace-nemoclaw 2>/dev/null | head -1)
[ -z "$PVC" ] && { echo "FATAL: no PVC found"; exit 1; }
echo "PVC=$PVC"

# 1. Real composio binary (the 122 MB upstream CLI) goes alongside the wrapper.
cp /home/azureuser/.composio/composio "$PVC/composio.real"
chmod 0755 "$PVC/composio.real"; chown 998:998 "$PVC/composio.real"

# 2. Per-user composio config (config.json, user_data.json, etc.) plus the
#    pre-provisioned ck_ key the MCP wrapper authenticates with.
mkdir -p "$PVC/.composio"
cp -r /home/azureuser/.composio/. "$PVC/.composio/"
rm -f "$PVC/.composio/composio"   # don't ship the binary inside the dotdir
chown -R 998:998 "$PVC/.composio"; chmod 0700 "$PVC/.composio"
find "$PVC/.composio" -type f -exec chmod 0600 {} \;
[ -f /etc/nemoclaw/composio-mcp-key ] && {
  cp /etc/nemoclaw/composio-mcp-key "$PVC/.composio/mcp-key"
  chmod 0600 "$PVC/.composio/mcp-key"; chown 998:998 "$PVC/.composio/mcp-key"
}

# 3. MCP wrapper script (Python — proxies to https://connect.composio.dev/mcp).
[ -f /etc/nemoclaw/composio-mcp-wrapper.py ] && {
  cp /etc/nemoclaw/composio-mcp-wrapper.py "$PVC/composio-mcp-wrapper.py"
  chmod 0755 "$PVC/composio-mcp-wrapper.py"; chown 998:998 "$PVC/composio-mcp-wrapper.py"
}

# 4. The 90-byte shim that exec's the venv interpreter against the wrapper.
printf '%s\n' '#!/bin/bash' \
  'exec /sandbox/.venv-composio/bin/python /sandbox/composio-mcp-wrapper.py "$@"' \
  > "$PVC/composio"
chmod 0755 "$PVC/composio"; chown 998:998 "$PVC/composio"

# 5. PATH symlink (the sandbox image already puts /sandbox/.local/bin on PATH,
#    so this is just for tab-completion / explicit lookups).
mkdir -p "$PVC/.local/bin"
ln -sf /sandbox/composio "$PVC/.local/bin/composio"
chown -R 998:998 "$PVC/.local"

# 6. Recreate the Python venv and pip-install composio inside the live sandbox.
#    NOTE: the host docker container is named `openshell-cluster-nemoclaw`, NOT
#    anything matching `k3s*` — older versions of this script grepped for `k3s`
#    and silently no-op'd. Hardcode the name.
POD=openshell-cluster-nemoclaw
docker exec "$POD" sh -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -n openshell nemoclaw -- runuser -u sandbox -- python3 -m venv /sandbox/.venv-composio" 2>&1 | tail -3
docker exec "$POD" sh -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -n openshell nemoclaw -- runuser -u sandbox -- /sandbox/.venv-composio/bin/pip install --quiet composio" 2>&1 | tail -3

# 7. Composio L7 network policy preset (egress allowlist for the MCP host).
[ -f /etc/nemoclaw/composio-policy.yaml ] && \
  sudo -iu azureuser nemoclaw nemoclaw policy-add \
    --from-file /etc/nemoclaw/composio-policy.yaml --yes 2>&1 | tail -3

# 8. Re-install the skill (carries our patched SKILL.md with the
#    "pre-installed; don't curl-install" guidance — without this the LLM
#    will run `curl … /install | bash` which 403s from the sandbox).
sudo -iu azureuser nemoclaw nemoclaw skill install \
  /home/azureuser/.agents/skills/composio 2>&1 | tail -3

echo "  ✓ composio restored"
REMOTE
```

Verify end-to-end with a single MCP call:

```bash
ssh azureuser@nemoclaw-p02f \
  'sudo -iu azureuser openshell sandbox exec -n nemoclaw --no-tty -- \
    /sandbox/composio execute GMAIL_FETCH_EMAILS -d "{\"max_results\":1}"' \
  | grep -E '"successful"|"error"'
# Expected: "successful": true,
```

A long-term cleaner fix is to bake the composio binary + skill into
the `extensions/` dir of the rebuild manifest, but that requires
extending NemoClaw's manifest schema. For now, this script is the
post-rebuild restore.

### Where the Composio key actually goes (if you want one in KV)

The Composio HTTP MCP endpoint at `https://connect.composio.dev/mcp`
authenticates via the `x-consumer-api-key` header, taking the `ck_`
key from `platform.composio.dev/settings`. There are two
already-seeded KV secrets in `kv-nc-p02f` from earlier debugging:

| Secret | Value type | Used by? |
|---|---|---|
| `composio-user-api-key` | `ck_…` | Nothing currently — the skill route doesn't read it. |
| `composio-org-id` | workspace slug | Nothing currently. |

These can stay (zero cost, ~24 chars each) or be deleted. They were
provisioned for an MCP/HTTP integration that turned out to be
unsupported by NemoClaw stock — see Dead End #3.

---

## When all else fails

```bash
# Full reset: deallocate, start, let auto-relight do its thing
az vm deallocate -g RG-NEMOCLAW -n vm-nemoclaw-p02f
az vm start -g RG-NEMOCLAW -n vm-nemoclaw-p02f
# Wait ~2 min, then test the bot. If still dead, see §1.
```

If a totally clean state is needed: `terraform destroy` + `terraform apply`
in the root stage rebuilds everything except the soft-deleted Key
Vault (which carries the secrets). See `specs/001-hardened-nemoclaw-deploy/quickstart.md`.
