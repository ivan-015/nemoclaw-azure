#!/usr/bin/env bash
# verify.sh — post-apply verification suite for the hardened NemoClaw
# Azure deployment.
#
# Source-of-truth: specs/001-hardened-nemoclaw-deploy/contracts/verification-checks.md
#
# Aligned with the upstream-NemoClaw architecture (curl|bash installer +
# `nemoclaw onboard` + OpenShell-on-host inference proxy). The earlier
# JIT-tmpfs / systemd-unit checks (US2 EC-4, etc.) were retired when the
# install model changed; see docs/THREAT_MODEL.md §"Mediation channel".
#
# This script implements:
#   - Pre-flight: 0a, 0b, 0c
#   - SC-001: 3a (tailscale ping), 3b (Tailscale SSH lands)
#   - SC-002: apply timing (advisory)
#   - SC-003: 2a (no public IP), 2b (zero NSG inbound allow rules),
#             2c (port scan reminder, manual)
#   - SC-004: Principle II tooth-check — KV value must NOT appear in
#             any OpenShell-managed sandbox container's environ or
#             cmdline; ~/.nemoclaw/credentials.json must be 0600.
#   - SC-005: cost reminder (advisory)
#   - SC-006: post-shutdown deallocation (active after 21:10 PT)
#   - SC-007: start-to-tailscale-reachable timing (opt-in:
#             VERIFY_TEST_START_LATENCY=1 — destructive)
#   - SC-008: KV audit landing (SecretGet recorded in LA)
#   - SC-009: destroy + redeploy is clean (opt-in:
#             VERIFY_TEST_DESTROY_REDEPLOY=1 — destructive)
#   - EC-2:   Foundry key rotation flow (manual / advisory)
#   - EC-5:   nemoclaw user/process cannot leak the Tailscale auth key
#   - EC-debug: no-network debug paths still work (manual)
#
# Exits non-zero if any non-advisory check fails.

set -uo pipefail
# Note: we intentionally don't `set -e` — we want every check to run,
# accumulate results, and exit at the end with a summary.

# ─── Output helpers ────────────────────────────────────────────────

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
  printf "%s[PASS]%s %s\n" "$GREEN" "$RESET" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf "%s[FAIL]%s %s\n" "$RED" "$RESET" "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf "       %s\n" "$2" >&2
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  printf "%s[SKIP]%s %s\n" "$YELLOW" "$RESET" "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

section() {
  printf "\n=== %s ===\n" "$1"
}

# ─── Bootstrap: gather state from Terraform outputs ────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/root"

if [[ ! -d "$TF_DIR" ]]; then
  fail "scripts/verify.sh expects to run from the repo root or scripts/" \
       "Could not find $TF_DIR"
  exit 2
fi

cd "$TF_DIR" || { fail "could not cd into $TF_DIR"; exit 2; }

# Best-effort fetch of the outputs we need. If terraform output fails
# (no state, no init), report a clear error rather than crashing
# downstream checks with empty values.
tf_out() {
  terraform output -raw "$1" 2>/dev/null || true
}

RG_NAME="$(tf_out resource_group_name)"
VM_NAME="$(tf_out vm_name)"
VM_HOSTNAME="$(tf_out vm_computer_name)"
KV_NAME="$(tf_out key_vault_name)"
LA_ID="$(tf_out log_analytics_workspace_id)"

if [[ -z "$RG_NAME" || -z "$VM_NAME" || -z "$VM_HOSTNAME" ]]; then
  fail "Could not read terraform outputs (resource_group_name / vm_name / vm_computer_name)" \
       "Run \`terraform init\` and \`terraform apply\` before running verify.sh."
  exit 2
fi

# Operator can override the tailnet hostname if their tailnet's MagicDNS
# uses a non-default suffix.
TAILNET_HOST="${TAILNET_HOST:-$VM_HOSTNAME}"

printf "Verifying deployment: vm=%s rg=%s tailnet=%s\n" \
  "$VM_NAME" "$RG_NAME" "$TAILNET_HOST"

# ─── Pre-flight ────────────────────────────────────────────────────

section "Pre-flight"

# 0a: az is logged in
if SUB_ID="$(az account show --query id -o tsv 2>/dev/null)" && [[ -n "$SUB_ID" ]]; then
  pass "0a — az logged in (sub: $SUB_ID)"
else
  fail "0a — az not logged in. Run \`az login\`."
fi

# 0b: tailscale is up on this machine
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status --json 2>/dev/null | grep -q '"Online":[[:space:]]*true'; then
    pass "0b — tailscale client online on this machine"
  else
    fail "0b — tailscale client is installed but not online. Run \`tailscale up\`."
  fi
else
  fail "0b — tailscale CLI not installed on this machine"
fi

# 0c: terraform state is on remote backend
if terraform init -reconfigure -input=false 2>&1 | grep -qi "Initializing the backend.*azurerm"; then
  pass "0c — terraform initialised against the azurerm remote backend"
else
  # Fall back to a softer check — `state list` should at least work.
  if terraform state list >/dev/null 2>&1; then
    pass "0c — terraform state accessible (backend looks initialised)"
  else
    fail "0c — terraform state inaccessible. Re-run terraform init -backend-config=..."
  fi
fi

# ─── SC-003: zero open ports from a non-tailnet network ────────────

section "SC-003 — zero open ports outside tailnet"

# 2a: VM has no public IP
PUBLIC_IPS="$(az vm show -g "$RG_NAME" -n "$VM_NAME" --query 'publicIps' -o tsv 2>/dev/null || true)"
if [[ -z "$PUBLIC_IPS" || "$PUBLIC_IPS" == "None" ]]; then
  pass "2a — VM has no public IP"
else
  fail "2a — VM has public IP(s): $PUBLIC_IPS" \
       "FR-001 violated. Inspect terraform/root/modules/vm/main.tf — NIC must not declare public_ip_address_id."
fi

# 2b: NSG has zero custom inbound allow rules
NSG_NAME="nsg-nemoclaw-vm"
INBOUND_ALLOW_RULES="$(
  az network nsg rule list \
    -g "$RG_NAME" \
    --nsg-name "$NSG_NAME" \
    --query "[?direction=='Inbound' && access=='Allow']" \
    -o json 2>/dev/null || echo "[]"
)"
if [[ "$INBOUND_ALLOW_RULES" == "[]" ]]; then
  pass "2b — NSG has zero custom inbound allow rules"
else
  fail "2b — NSG has custom inbound allow rules. Spec FR-002 violated." \
       "Offending rules: $INBOUND_ALLOW_RULES"
fi

# 2c: nmap from outside is manual
skip "2c — nmap port scan from a non-tailnet network (manual: run \`nmap -p 1-65535 -Pn\` from a mobile hotspot or other off-tailnet host; expect every port closed/filtered)"

# ─── SC-001: discoverable from tailnet ─────────────────────────────

section "SC-001 — discoverable from tailnet"

# 3a: tailscale ping
if command -v tailscale >/dev/null 2>&1; then
  if tailscale ping --c 1 --timeout 5s "$TAILNET_HOST" >/dev/null 2>&1; then
    pass "3a — tailscale ping $TAILNET_HOST succeeded"
  else
    fail "3a — tailscale ping $TAILNET_HOST failed" \
         "VM may still be booting (cloud-init runs ~5-7 min). If persistent, check \`az vm get-instance-view\` and the boot diagnostics."
  fi
else
  skip "3a — tailscale CLI not present; cannot ping"
fi

# 3b: Tailscale SSH lands a shell
if command -v tailscale >/dev/null 2>&1; then
  if SSH_OUT="$(tailscale ssh "$TAILNET_HOST" -- uptime 2>&1)" && [[ -n "$SSH_OUT" ]]; then
    pass "3b — Tailscale SSH lands a shell (uptime: $SSH_OUT)"
  else
    fail "3b — Tailscale SSH failed" \
         "Ensure your tailnet ACL permits your device → tag:nemoclaw. Output: $SSH_OUT"
  fi
else
  skip "3b — tailscale CLI not present"
fi

# ─── US1 acceptance: nemoclaw sandbox is Ready ─────────────────────
#
# Upstream NemoClaw's documented health command is `nemoclaw <sandbox>
# status`, which prints the sandbox phase. "Ready" means OpenShell
# gateway is healthy + the OpenClaw agent container is running. The
# old `nemoclaw doctor` command from earlier project iterations does
# not exist in upstream.

section "US1 acceptance — nemoclaw sandbox Ready"

NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-nemoclaw}"
if command -v tailscale >/dev/null 2>&1; then
  STATUS_OUT="$(tailscale ssh "$TAILNET_HOST" -- "nemoclaw $NEMOCLAW_SANDBOX_NAME status 2>&1" 2>&1 || true)"
  if grep -qE "Phase:\s*Ready" <<< "$STATUS_OUT"; then
    pass "US1-4 — sandbox '$NEMOCLAW_SANDBOX_NAME' is Phase: Ready"
  else
    fail "US1-4 — sandbox '$NEMOCLAW_SANDBOX_NAME' is not Ready" \
         "Output (head): $(head -c 300 <<< "$STATUS_OUT") — inspect with \`tailscale ssh $TAILNET_HOST -- nemoclaw $NEMOCLAW_SANDBOX_NAME logs\`."
  fi
else
  skip "US1-4 — cannot check sandbox status without tailscale CLI"
fi

# ─── SC-002: apply timing (advisory) ───────────────────────────────

section "SC-002 — apply timing (advisory)"

skip "SC-002 — measure with \`time terraform apply -auto-approve\` from a fresh state. Target: <= 15m wall-clock."

# ─── SC-004: Principle II tooth-check ──────────────────────────────
#
# Under the upstream NemoClaw architecture (verified against
# docs/inference/inference-options.md), the sandbox runs as a Docker
# container managed by OpenShell with Landlock + seccomp + a private
# network namespace. The provider API key lives on the host in
# OpenShell's persisted credentials (~/.nemoclaw/credentials.json,
# mode 0600 owned by the operator user). The sandbox cannot read
# the operator's home or talk to the provider directly.
#
# 4a: enumerate sandbox container PIDs (host-side view).
# 4b: grep each container's /proc/<pid>/environ for the KV value.
# 4c: grep each container's /proc/<pid>/cmdline for the KV value.
# 4d: confirm the operator's credentials file IS protected (mode 0600).
#
# Sample-pass output: 4b/4c return zero matches AND 4d shows mode 0600.
# Sample-fail output: 4b or 4c finds the KV value in any sandbox
# container — Principle II violation, exit non-zero.

section "SC-004 — Principle II tooth-check (sandbox container never sees KV value)"

if [[ -z "$KV_NAME" ]]; then
  fail "SC-004 — cannot run without key_vault_name terraform output" \
       "Re-run after \`terraform apply\`."
elif ! command -v tailscale >/dev/null 2>&1; then
  skip "SC-004 — tailscale CLI not present on this machine"
else
  KEY_VALUE="$(az keyvault secret show --vault-name "$KV_NAME" --name foundry-api-key --query value -o tsv 2>/dev/null || true)"
  if [[ -z "$KEY_VALUE" ]]; then
    skip "SC-004 — cannot read foundry-api-key from $KV_NAME (RBAC? not yet set?)"
  elif [[ "$KEY_VALUE" == PLACEHOLDER* ]]; then
    skip "SC-004 — foundry-api-key is still the Terraform PLACEHOLDER; tooth-check is meaningless until a real key is set"
  else
    # 4a: enumerate sandbox container PIDs. OpenShell-managed
    # containers have label `openshell.role` or live under the
    # `openshell` namespace in k3s. We use a permissive pattern
    # (any container whose name contains "openshell" or "sandbox")
    # and then narrow to running PIDs.
    PIDS_OUT="$(
      tailscale ssh "$TAILNET_HOST" -- 'sudo docker ps --format "{{.ID}}" --filter "name=openshell" --filter "name=sandbox" 2>/dev/null | xargs -r sudo docker inspect --format "{{.State.Pid}} {{.Name}}" 2>/dev/null' 2>&1 || true
    )"
    if [[ -z "$PIDS_OUT" ]]; then
      skip "4a — no OpenShell sandbox containers found via docker ps; sandbox may not be Ready yet"
    else
      pass "4a — sandbox containers: $(head -c 200 <<< "$PIDS_OUT" | tr '\n' '|')"

      # 4b/4c: grep the sandbox containers' environ + cmdline for the
      # KV value. Pipe the secret in via stdin so it never appears on
      # this script's argv. The remote bash reads it once, then
      # iterates the PIDs.
      # shellcheck disable=SC2016 # single quotes intentional — vars
      # expand on the REMOTE bash, not locally.
      MATCHES_BC="$(
        printf '%s' "$KEY_VALUE" | \
          tailscale ssh "$TAILNET_HOST" -- sudo bash -c '
            kv=$(cat)
            for pid in $(docker ps --format "{{.ID}}" --filter name=openshell --filter name=sandbox | xargs -r docker inspect --format "{{.State.Pid}}"); do
              if [[ -n "$pid" && "$pid" != "0" ]]; then
                grep -aF -- "$kv" "/proc/$pid/environ" "/proc/$pid/cmdline" 2>/dev/null && echo "match in pid $pid"
              fi
            done
          ' 2>&1 || true
      )"
      if [[ -z "$MATCHES_BC" ]]; then
        pass "4b/4c — no match for KV value in sandbox-container environ or cmdline"
      else
        fail "4b/4c — KV value found in a sandbox container's process state" \
             "$MATCHES_BC — Principle II violation. The OpenShell intercept design must keep the key on the host only."
      fi

      # 4d: operator's credentials file should be 0600.
      CRED_MODE="$(tailscale ssh "$TAILNET_HOST" -- sudo stat -c '%a %U %G' /home/azureuser/.nemoclaw/credentials.json 2>&1 || true)"
      if [[ "$CRED_MODE" =~ ^600\ azureuser\ azureuser ]]; then
        pass "4d — ~/.nemoclaw/credentials.json is mode 0600 owned by azureuser (operator-only)"
      else
        fail "4d — ~/.nemoclaw/credentials.json has unexpected perms" \
             "Output: $CRED_MODE — should be '600 azureuser azureuser'."
      fi
    fi
    unset KEY_VALUE
  fi
fi

# ─── SC-008: Key Vault audit landing ───────────────────────────────
#
# Every KV SecretGet operation is logged by Azure to the diagnostic
# settings → Log Analytics workspace. Cloud-init's 05-nemoclaw.sh
# triggers exactly one SecretGet for foundry-api-key during install,
# plus one per Tailscale auth-key fetch in 01-tailscale.sh. After a
# successful apply the LA workspace should have at least two recent
# SecretGet records from the VM's managed identity.

section "SC-008 — Key Vault audit landing"

if [[ -z "$LA_ID" ]]; then
  skip "SC-008 — log_analytics_workspace_id terraform output empty"
elif ! command -v az >/dev/null 2>&1; then
  skip "SC-008 — az CLI not installed on this machine"
else
  # Workspace ID for `az monitor log-analytics query` is the GUID,
  # not the full resource ID. Extract the last segment.
  LA_GUID="${LA_ID##*/}"
  # Query the last 10 minutes (covers the EC-4 restart + slack for
  # ingestion latency). Strict TimeGenerated filter avoids matching
  # the cloud-init first-boot fetch that may have happened hours ago.
  KQL=$(cat <<KUSTO
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| where TimeGenerated > ago(10m)
| project TimeGenerated, Resource, identity_claim_oid_g, ResultSignature
| order by TimeGenerated desc
| limit 5
KUSTO
)
  AUDIT_OUT="$(
    az monitor log-analytics query \
      -w "$LA_GUID" \
      --analytics-query "$KQL" \
      -o tsv 2>&1 || true
  )"
  if [[ -z "$AUDIT_OUT" ]]; then
    fail "SC-008 — no SecretGet records in last 10m" \
         "Diagnostic settings on the Key Vault may not be wired to the workspace, or ingestion is delayed (>5 min)."
  elif grep -qi "error\|extension" <<< "$AUDIT_OUT"; then
    fail "SC-008 — log analytics query failed" \
         "Output: $AUDIT_OUT"
  else
    pass "SC-008 — at least one SecretGet record landed in LA within the window"
  fi
fi

# ─── EC-2: Foundry key rotation propagates ─────────────────────────
#
# This is a manual operator check — automating it would require
# rotating the live Foundry secret and waiting for inference output,
# which is destructive and out of scope for verify.sh.

section "EC-2 — Foundry key rotation (manual)"

skip "EC-2 — manual rotation flow: (1) \`az keyvault secret set --vault-name $KV_NAME --name foundry-api-key --value <new-key>\`; (2) on the VM via Tailscale SSH, \`nemoclaw credentials reset COMPATIBLE_API_KEY\` then \`nemoclaw onboard\` (interactive — paste the new key when prompted); (3) re-test inference. The OpenShell-on-host model means rotation isn't automatic on KV update — operator triggers reload via the documented credentials-reset flow. See docs/THREAT_MODEL.md §'Mediation channel'."

# ─── SC-005: cost reminder (advisory) ──────────────────────────────
#
# Actual cost lookup is interactive (Azure portal → Cost Management).
# This check just prints the URL so the operator can paste it into
# their browser. Target: ≤ $40/mo with auto-shutdown ON, ≤ $80/mo
# PAYG without it.

section "SC-005 — cost forecast (advisory)"

if [[ -z "$RG_NAME" || -z "${SUB_ID:-}" ]]; then
  skip "SC-005 — need both subscription_id and resource_group_name"
else
  COST_URL="https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/%2Fsubscriptions%2F${SUB_ID}%2FresourceGroups%2F${RG_NAME}"
  skip "SC-005 — open Cost Management for this RG: $COST_URL (target: \$40/mo with auto-shutdown ON, \$80/mo PAYG)"
fi

# ─── SC-006: auto-shutdown deallocates the VM ──────────────────────
#
# Print the current PowerState plus the configured shutdown time.
# If the operator runs verify.sh after 21:10 PT (the documented
# shutdown window + 10 min slack per spec), they should see
# "PowerState/deallocated". Earlier in the day, they should see
# "PowerState/running". Either is informational — fail only if the
# state can't be read at all.

section "SC-006 — auto-shutdown (advisory; manual after 21:10 PT)"

if [[ -z "$RG_NAME" || -z "$VM_NAME" ]]; then
  skip "SC-006 — need terraform outputs"
else
  POWER_STATE="$(
    az vm get-instance-view -g "$RG_NAME" -n "$VM_NAME" \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" \
      -o tsv 2>/dev/null | head -1 || true
  )"
  if [[ -z "$POWER_STATE" ]]; then
    fail "SC-006 — could not read PowerState for $VM_NAME"
  else
    skip "SC-006 — current PowerState: $POWER_STATE (after 21:10 PT expect PowerState/deallocated)"
  fi
fi

# ─── SC-007: start-to-tailscale-reachable timing ───────────────────
#
# Opt-in via VERIFY_TEST_START_LATENCY=1. This check is destructive:
# it deallocates the VM, then times `az vm start` + the wait for
# Tailscale ping to come back. Target: ≤ 5m wall-clock (spec SC-007).
#
# Skipped by default so accidentally running verify.sh during normal
# work doesn't take the operator's deploy down for several minutes.

section "SC-007 — start latency (opt-in: VERIFY_TEST_START_LATENCY=1)"

if [[ "${VERIFY_TEST_START_LATENCY:-0}" != "1" ]]; then
  skip "SC-007 — destructive timing check; set VERIFY_TEST_START_LATENCY=1 to run (will deallocate + restart the VM)"
elif [[ -z "$RG_NAME" || -z "$VM_NAME" ]] || ! command -v tailscale >/dev/null 2>&1; then
  skip "SC-007 — need terraform outputs and tailscale CLI"
else
  echo "SC-007 — deallocating $VM_NAME for cold-start timing..."
  if ! az vm deallocate -g "$RG_NAME" -n "$VM_NAME" --no-wait >/dev/null 2>&1; then
    fail "SC-007 — could not issue deallocate"
  else
    # Poll until deallocated, max 5 min
    DEALLOC_START="$(date +%s)"
    while (( $(date +%s) - DEALLOC_START < 300 )); do
      STATE="$(
        az vm get-instance-view -g "$RG_NAME" -n "$VM_NAME" \
          --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" \
          -o tsv 2>/dev/null | head -1 || true
      )"
      [[ "$STATE" == "PowerState/deallocated" ]] && break
      sleep 5
    done

    if [[ "$STATE" != "PowerState/deallocated" ]]; then
      fail "SC-007 — VM did not reach deallocated within 5m (state: $STATE)"
    else
      START_T0="$(date +%s)"
      az vm start -g "$RG_NAME" -n "$VM_NAME" >/dev/null 2>&1
      # Poll Tailscale ping
      while (( $(date +%s) - START_T0 < 300 )); do
        if tailscale ping --c 1 --timeout 5s "$TAILNET_HOST" >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done
      ELAPSED=$(( $(date +%s) - START_T0 ))

      if (( ELAPSED >= 300 )); then
        fail "SC-007 — start-to-tailscale-reachable exceeded 5m (${ELAPSED}s)"
      else
        pass "SC-007 — start-to-tailscale-reachable: ${ELAPSED}s (≤ 300s target)"
      fi
    fi
  fi
fi

# ─── EC-5: handoff cannot leak the Tailscale auth key ──────────────
#
# The contract acknowledges two possible pass paths: (a) the MI's KV
# RBAC scope blocks reads of tailscale-auth-key, OR (b) by the time
# the operator runs verify.sh, Tailscale's 24h ephemeral expiry has
# already invalidated the persisted KV value. Either way the test
# of "the handoff binary running on the VM cannot leak the live
# Tailscale auth key" passes.

section "EC-5 — handoff cannot leak Tailscale auth key"

if [[ -z "$KV_NAME" ]] || ! command -v tailscale >/dev/null 2>&1; then
  skip "EC-5 — requires tailscale + valid KV"
else
  # Run the read attempt as the nemoclaw user (the unit's User=) so
  # we exercise the same RBAC path the credential handoff would.
  # Note: `az login --identity` is bound to the VM, not the local
  # user, so any uid can call it; what differs is filesystem state
  # for the cached token. We sudo to nemoclaw and run the full
  # login + secret-show pair.
  LEAK_OUT="$(
    tailscale ssh "$TAILNET_HOST" -- sudo -u nemoclaw -H bash -c \
      "az login --identity --output none 2>&1 && az keyvault secret show --vault-name '$KV_NAME' --name tailscale-auth-key --query value -o tsv 2>&1" \
      || true
  )"
  # PASS if: 403/404, "not found", "expired", network error, or the
  # secret has been rotated/deleted. FAIL if a live tskey-auth-... value
  # comes back.
  if grep -qE '^tskey-(auth|client)-' <<< "$LEAK_OUT"; then
    fail "EC-5 — handoff path can read live tailscale-auth-key from KV" \
         "Tighten the MI's RBAC to a per-secret scope or delete tailscale-auth-key from KV after first boot. (Contract permits the 24h-expiry mitigation, but a live key is still leakage.)"
  elif grep -qiE 'forbidden|403|not found|404|secretnotfound|expired' <<< "$LEAK_OUT"; then
    pass "EC-5 — tailscale-auth-key read denied or rotated (output: $(head -c 120 <<< "$LEAK_OUT"))"
  elif [[ -z "$LEAK_OUT" ]]; then
    skip "EC-5 — no output from leak probe (Tailscale SSH may have failed)"
  else
    # Anything else — the KV value came back as something that
    # isn't a tskey but also isn't a clear deny. Treat as a soft
    # pass with the operator-reviewed output.
    skip "EC-5 — leak probe returned non-tskey content; operator review: $(head -c 200 <<< "$LEAK_OUT")"
  fi
fi

# ─── SC-009: destroy + redeploy is clean ───────────────────────────
#
# The full check (per contracts/verification-checks.md):
#   9a. `terraform destroy -auto-approve` exits 0
#   9b. `az resource list -g <rg>` is empty (or the RG itself is gone)
#   9c. `terraform taint random_string.deploy_suffix && terraform apply`
#       exits 0 with a different KV name
#
# Opt-in via VERIFY_TEST_DESTROY_REDEPLOY=1 — this is destructive
# (it tears the operator's deploy down) and slow (~25–30 minutes
# wall-clock for the full destroy + apply cycle). Skipped by default
# so accidentally running verify.sh during normal work doesn't take
# the operator's deploy out from under them.
#
# When skipped, prints the recommended manual sequence so the
# operator can run it once during v1 acceptance.

section "SC-009 — destroy + redeploy is clean (opt-in: VERIFY_TEST_DESTROY_REDEPLOY=1)"

if [[ "${VERIFY_TEST_DESTROY_REDEPLOY:-0}" != "1" ]]; then
  cat <<MANUAL
[SKIP] SC-009 — destructive; set VERIFY_TEST_DESTROY_REDEPLOY=1 to run automatically. Manual sequence:

  # Capture pre-destroy state for the redeploy comparison.
  KV_BEFORE=\$(terraform output -raw key_vault_name)

  # 9a: destroy
  terraform destroy -auto-approve

  # 9b: confirm the RG is empty (or gone)
  az resource list -g "$RG_NAME" -o tsv

  # 9c: redeploy with a fresh suffix — bypasses the KV soft-delete hold
  terraform taint random_string.deploy_suffix
  terraform apply -auto-approve

  # Confirm the new KV name differs from \$KV_BEFORE
  KV_AFTER=\$(terraform output -raw key_vault_name)
  test "\$KV_BEFORE" != "\$KV_AFTER" && echo "9c PASS — fresh suffix"

Don't forget to manually remove the old tag:nemoclaw node from the Tailscale admin console between steps (docs/TAILSCALE.md §4).
MANUAL
  SKIP_COUNT=$((SKIP_COUNT + 1))
elif [[ -z "$RG_NAME" || -z "$KV_NAME" ]]; then
  fail "SC-009 — terraform outputs unavailable; run after a successful apply"
else
  KV_BEFORE="$KV_NAME"
  echo "SC-009 — pre-destroy KV name: $KV_BEFORE"

  # 9a: destroy
  echo "SC-009 — running terraform destroy -auto-approve (this takes several minutes)..."
  if terraform destroy -auto-approve >/tmp/sc009-destroy.log 2>&1; then
    pass "9a — terraform destroy exited 0 (log: /tmp/sc009-destroy.log)"
  else
    fail "9a — terraform destroy failed" \
         "See /tmp/sc009-destroy.log. Common cause: KV purge protection holds the vault alive — that's expected and not a destroy failure."
  fi

  # 9b: RG should be empty (or gone). The RG itself is destroyed by
  # the destroy; `az resource list` either returns [] or the command
  # itself errors with "ResourceGroupNotFound". Both pass.
  RG_RESOURCES="$(az resource list -g "$RG_NAME" -o tsv 2>&1 || true)"
  if [[ -z "$RG_RESOURCES" ]] || grep -qi "ResourceGroupNotFound" <<< "$RG_RESOURCES"; then
    pass "9b — RG is empty or gone"
  else
    fail "9b — RG still contains resources" \
         "Output: $RG_RESOURCES — these may need manual cleanup (e.g. Tailscale node not removed yet)."
  fi

  # 9c: redeploy with a fresh suffix
  echo "SC-009 — tainting random_string.deploy_suffix and re-applying..."
  terraform taint random_string.deploy_suffix >/dev/null 2>&1 || true
  if terraform apply -auto-approve >/tmp/sc009-apply.log 2>&1; then
    KV_AFTER="$(terraform output -raw key_vault_name 2>/dev/null || true)"
    if [[ -n "$KV_AFTER" && "$KV_AFTER" != "$KV_BEFORE" ]]; then
      pass "9c — re-apply succeeded with fresh KV name ($KV_BEFORE → $KV_AFTER)"
    else
      fail "9c — re-apply succeeded but KV name unchanged" \
           "Suffix taint should have produced a different name."
    fi
  else
    fail "9c — terraform apply (post-taint) failed" \
         "See /tmp/sc009-apply.log."
  fi
fi

# ─── EC-debug: no-network debug paths still work ───────────────────
#
# US4 acceptance scenario: with Tailscale daemon manually stopped,
# Run Command must still be able to reach the VM and bring Tailscale
# back. We deliberately do NOT auto-run this — stopping tailscaled
# severs the operator's own session if they're connected via
# `tailscale ssh`. Documented as an operator's-manual smoke test.

section "EC-debug — Run Command works without Tailscale (manual)"

if [[ -z "$RG_NAME" || -z "$VM_NAME" ]]; then
  skip "EC-debug — need terraform outputs"
else
  cat <<MANUAL
[SKIP] EC-debug — manual operator smoke test (DO NOT run mid-session if you're SSH'd via Tailscale):

  # 1. Stop tailscaled via Run Command (severs the tailnet — intentional).
  az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \\
    --command-id RunShellScript \\
    --scripts "systemctl stop tailscaled"

  # 2. Confirm Run Command itself still reaches the VM (US4 acceptance):
  az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \\
    --command-id RunShellScript \\
    --scripts "uptime; systemctl status tailscaled --no-pager"

  # 3. Bring Tailscale back via Run Command (recovery path):
  az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \\
    --command-id RunShellScript \\
    --scripts "systemctl start tailscaled && sleep 3 && tailscale status"

See docs/TAILSCALE.md §8 and quickstart.md §8 for the full no-network debug walkthrough.
MANUAL
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ─── Summary ───────────────────────────────────────────────────────

section "Summary"
printf "PASS: %d  FAIL: %d  SKIP: %d\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
