# Tailscale: Auth-Key Lifecycle, ACL, and Recovery

**Status**: v1 — manual-managed auth key, manual node revocation on destroy.
**Spec**: FR-003, FR-012, EC "Tailscale outage", EC "auth key expired".
**Research**: R3 (kernel mode), R5 revised (auth-key lifecycle).

This document is the operator's reference for the Tailscale side of
the deploy. Anything Azure-side lives in the spec / plan / research.

---

## 1. Auth-key generation

Generate a fresh key in the Tailscale admin console **before each
first apply** (or after destroy + redeploy).

Required parameters:

| Parameter | Value | Why |
|---|---|---|
| **Reusable** | `false` | One-time use is FR-012's intent; reusable keys are long-lived credentials. |
| **Ephemeral** | `true` | Node auto-removes from the tailnet when offline > 24h; reduces residue if `terraform destroy` is forgotten. |
| **Pre-approved** | `true` | Skips the manual approval step in the admin console; cloud-init cannot click "approve". |
| **Expiration** | `24 hours` | The persisted KV-side value becomes useless after this window — the v1 mitigation for the residual KV-stored copy. |
| **Tags** | `tag:nemoclaw` | Scopes the device under the operator's ACL; matches `var.tailscale_tag` default. |

Where: <https://login.tailscale.com/admin/settings/keys> → "Generate
auth key…".

The key is shown **once**; copy it before closing the dialog.

---

## 2. Pre-staging the key in Key Vault

The two-stage apply (per spec FR-018) runs Key Vault provisioning
first, then the operator seeds the secrets, then the full apply
finishes. The placeholder secret created by Terraform is overwritten:

```bash
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name tailscale-auth-key \
  --value "$TS_AUTH_KEY"
```

Ergonomics tips:

- Pipe the auth key from your password manager rather than pasting it
  on the command line if shell history is a concern.
- The Key Vault's diagnostic settings record this `SecretSet`
  operation with the operator's identity — visible in Log Analytics.

---

## 3. ACL recommendation

The operator's tailnet ACL should restrict who can reach
`tag:nemoclaw` devices. Suggested snippet (drop into the Tailscale
admin console "Access Controls" tab; merge with the operator's
existing ACL — do not replace):

```jsonc
{
  "tagOwners": {
    // Only the operator's account may issue or apply tag:nemoclaw.
    "tag:nemoclaw": ["autogroup:owner"]
  },

  "acls": [
    // Operator's own devices (tag:personal) can reach NemoClaw.
    {
      "action": "accept",
      "src":    ["tag:personal"],
      "dst":    ["tag:nemoclaw:*"]
    }
    // Add other tags here only if a third device legitimately needs
    // to reach NemoClaw. The default is "no other tag can reach it."
  ],

  "ssh": [
    // Tailscale SSH from the operator's devices into the VM, no
    // password / key exchange. Replace `<your-username>` with the
    // Linux account name on the VM you want to SSH as.
    {
      "action": "accept",
      "src":    ["autogroup:owner"],
      "dst":    ["tag:nemoclaw"],
      "users":  ["root", "<your-username>", "nemoclaw"]
    }
  ]
}
```

Notes:

- This deploy does NOT rely on Tailscale SSH for the credential
  handoff or any in-deploy mechanism. Tailscale SSH is purely an
  operator-convenience admin path.
- If you do not use tags on your other devices, replace `tag:personal`
  with `autogroup:owner` (your own user, every device).

---

## 4. On `terraform destroy` — manual node revocation (v1)

Tailscale auth keys auto-revoke their *issuance* on destroy (the key
is single-use), but the *node* itself remains registered in the tailnet
until removed. v1 does not automate node revocation (research R5
revised — would need a Tailscale API token, which itself becomes a
long-lived credential).

After `terraform destroy`:

1. Visit <https://login.tailscale.com/admin/machines>.
2. Find the node with hostname `nemoclaw-<suffix>` (the suffix matches
   `random_string.deploy_suffix`).
3. Click the row → "Remove" → confirm.

This step is idempotent — if the node already auto-removed via the
ephemeral expiry, "Remove" is a no-op.

**v2 candidate**: a `null_resource` on destroy that calls the
Tailscale REST API. Requires storing a Tailscale API key in Key Vault
and granting cloud-init read access; deferred until a real ergonomic
need surfaces.

---

## 5. The 24h expiry as the v1 KV-side mitigation

Spec FR-012 requires the Tailscale auth key not be reachable by
NemoClaw at any time. The v1 design achieves this by:

1. Cloud-init (running as root, *before NemoClaw exists*) fetches the
   key, runs `tailscale up`, scrubs the in-memory copy.
2. The cloud-init log lines that contained the key are overwritten
   with `xxx`s before cloud-init's log is persisted.
3. The KV-side copy persists, but Tailscale's 24h ephemeral expiry
   makes it useless after 24h whether or not the operator deletes it.

**v2 candidate**: a `null_resource` `local-exec` that calls
`az keyvault secret delete` after `tailscale up` reports success.
Cut from v1 per the user's trim #4 — flaky `local-exec` dependency
on the operator's `az login` being authenticated at apply time was
not worth the marginal mitigation given the 24h natural expiry.

---

## 6. Kernel mode vs. userspace mode

v1 uses **kernel-mode Tailscale** (`tailscaled` runs as root, opens
`tun0`). Per research R3:

- Kernel mode is the documented Tailscale default for Linux servers.
- It operates at the host network namespace level, *outside*
  NemoClaw's sandbox — exactly the right scope for an admin path.
- Userspace mode (`TS_USERSPACE=true`) traverses namespaces but is
  noticeably slower and surfaces edge cases around `iptables` /
  `nftables`.

**Fallback**: if kernel-mode Tailscale conflicts with NemoClaw's
network namespaces (it shouldn't — NemoClaw talks to Foundry from
inside its own netns directly to the public internet), switch to
userspace mode by setting `TS_USERSPACE=true` in the systemd unit
override and re-running cloud-init via Run Command. Out-of-scope at
v1 unless the smoke test surfaces a real conflict.

---

## 7. No-network debug walkthrough (when Tailscale itself is broken)

If Tailscale is unhealthy on the VM and you cannot SSH via the
tailnet, use the Azure control plane. None of these paths require
any inbound NSG rule.

### 7a. Run Command — execute a script on the VM

```bash
az vm run-command invoke \
  --resource-group "$RG_NAME" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "systemctl status tailscaled.service --no-pager"
```

Common follow-ups:

```bash
# Restart Tailscale.
az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "systemctl restart tailscaled.service && tailscale status"

# Read the last 200 lines of journald for tailscaled.
az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "journalctl -u tailscaled.service -n 200 --no-pager"

# Re-register the node (only if the existing registration is bad —
# requires a freshly minted auth key in KV).
az vm run-command invoke -g "$RG_NAME" -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "tailscale logout && /usr/local/bin/nemoclaw-bootstrap-tailscale.sh"
```

### 7b. Serial console — when even userspace networking is broken

Azure portal → VM blade → "Boot diagnostics" → "Serial console". Logs
in as the cloud-init user. Useful for inspecting `/var/log/cloud-init.log`
when cloud-init itself failed.

### 7c. Boot diagnostics — read the boot log without a session

```bash
az vm boot-diagnostics get-boot-log \
  --resource-group "$RG_NAME" \
  --name "$VM_NAME"
```

Captures the kernel + cloud-init output up to the most recent boot.
Useful for postmortems on a deallocated VM.

---

## 8. When Tailscale itself is broken

Tailscale outages, account suspension, or coordination-plane bugs
make the tailnet unusable. The deploy continues running NemoClaw's
existing work; only the operator's *access* is impaired. Two
no-network recovery paths cover every variant — neither requires
opening any inbound NSG rule:

- **Run Command** (§7a above) — one-shot shell snippets executed via
  the Azure VM agent. The first thing to reach for; works as long
  as the VM is running and the agent is healthy. Preferred for
  diagnostics, restarts, and re-running cloud-init scripts.
- **Serial console** (§7b above) — interactive console attached via
  the Azure portal. Use when Run Command isn't responsive (kernel
  panic, agent down, cloud-init hung pre-getty) or when you need a
  real terminal to step through recovery interactively.

Recovery sequence:

1. Check <https://status.tailscale.com> for an active incident.
2. If the issue is on Tailscale's side, wait it out — the VM is
   fine. Use **Run Command** (§7a) for any in-flight admin needs.
3. If the issue is on the VM side (`tailscaled` crashed, registration
   expired, etc.), use **Run Command** to diagnose and recover. If
   `tailscaled` won't even respond to `systemctl restart` over Run
   Command, escalate to the **serial console** (§7b) and inspect
   the daemon's state interactively.
4. If the issue is on the *account* side (you got logged out of your
   Tailscale account), log back in on your laptop; the tailnet
   resumes. The VM doesn't care.
5. Last resort: `terraform destroy` + redeploy with a fresh auth key.
   Lost work: ephemeral state on the VM (NemoClaw conversation
   history, transient state). Persistent state in Key Vault and
   Terraform state is unaffected.

---

## Cross-references

- Spec FR-003, FR-012, EC "Tailscale outage".
- Research R3 (kernel vs userspace), R5 revised (auth-key lifecycle).
- `cloud-init/scripts/01-tailscale.sh` — implements the fetch + register + scrub.
- `contracts/kv-secret-layout.md` — KV secret naming.
