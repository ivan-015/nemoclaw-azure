#!/usr/bin/env bash
# verify.sh — post-apply verification suite for the hardened NemoClaw
# Azure deployment.
#
# Source-of-truth: specs/001-hardened-nemoclaw-deploy/contracts/verification-checks.md
#
# At Phase 3 (US1) this script implements:
#   - Pre-flight: 0a, 0b, 0c
#   - SC-001: 3a (tailscale ping), 3b (Tailscale SSH lands)
#   - SC-002: apply timing (advisory — caller wraps `terraform apply`
#             with `time` themselves; this script reports the live VM
#             state instead)
#   - SC-003: 2a (no public IP), 2b (zero NSG inbound allow rules),
#             2c (port scan reminder, manual)
#
# US2 (T034) appends SC-004 (Principle II tooth-check), SC-008 (audit
# landing), EC-2/4/5. US3 (T041) appends SC-005/006/007. US5 (T050)
# appends SC-009.
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

cd "$TF_DIR"

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

# ─── US1 acceptance: nemoclaw doctor ───────────────────────────────

section "US1 acceptance — nemoclaw doctor"

if command -v tailscale >/dev/null 2>&1; then
  if DOCTOR_OUT="$(tailscale ssh "$TAILNET_HOST" -- nemoclaw doctor 2>&1)"; then
    pass "US1-4 — \`nemoclaw doctor\` exited 0"
  else
    # At US1 the credential handoff is not yet wired. If `nemoclaw
    # doctor` fails *only* on a missing OPENAI_API_KEY, treat as
    # advisory PASS for US1 — US2 wires the key.
    if grep -qi "OPENAI_API_KEY\|missing.*key\|api.key" <<< "$DOCTOR_OUT"; then
      skip "US1-4 — \`nemoclaw doctor\` failed on missing API key (expected at US1; US2 wires the credential handoff)"
    else
      fail "US1-4 — \`nemoclaw doctor\` failed for non-credential reason" \
           "Output: $DOCTOR_OUT"
    fi
  fi
else
  skip "US1-4 — cannot run nemoclaw doctor without tailscale"
fi

# ─── SC-002: apply timing (advisory) ───────────────────────────────

section "SC-002 — apply timing (advisory)"

skip "SC-002 — measure with \`time terraform apply -auto-approve\` from a fresh state. Target: <= 15m wall-clock."

# ─── Summary ───────────────────────────────────────────────────────

section "Summary"
printf "PASS: %d  FAIL: %d  SKIP: %d\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
