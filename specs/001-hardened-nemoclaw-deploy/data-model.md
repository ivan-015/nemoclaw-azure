# Phase 1 Data Model: Hardened NemoClaw Azure Deployment (v1)

**Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)
**Date**: 2026-04-25

This is an infrastructure project. "Data model" here means the
*configuration entities* the system manipulates — Terraform inputs,
outputs, Azure resources and their relationships, Key Vault secret
layout, broker IPC payloads, and on-VM filesystem locations.
Separate detailed contracts live under `contracts/`.

---

## 1. Terraform Input Variables (operator-facing API)

The full contract (types, validation rules, defaults) is in
[contracts/tfvars-inputs.md](./contracts/tfvars-inputs.md). Summary:

| Variable | Purpose | Default | Sensitive |
|---|---|---|---|
| `subscription_id` | Personal Azure subscription | (required) | no |
| `location` | Azure region | `centralus` | no |
| `vm_sku` | VM size | `Standard_B4als_v2` | no |
| `nemoclaw_version` | Upstream release tag (no default) | (required) | no |
| `foundry_endpoint` | Azure AI Foundry endpoint URL | (required) | no |
| `foundry_deployments` | Map of deployment name → model + API version | (required) | no |
| `tailscale_tag` | Tag advertised by the VM on the tailnet (default `tag:nemoclaw`) | `tag:nemoclaw` | no |
| `auto_shutdown_enabled` | Whether to enable nightly shutdown | `true` | no |
| `auto_shutdown_local_time` | Time-of-day for shutdown | `21:00` | no |
| `auto_shutdown_tz` | Timezone | `America/Los_Angeles` | no |
| `tags` | Map merged with the four mandatory tags | `{}` | no |
| `cost_center` | Tag value (overrides `personal` default) | `personal` | no |
| `owner` | Owner tag (email or GitHub handle) | (required) | no |

Notable validation:

- `location` MUST be a recognised Azure region.
- `vm_sku` MUST be a SKU with ≥ 4 vCPU and ≥ 8 GB RAM (a
  `validation` block runs against a known-good list to fail-fast).
- `foundry_endpoint` MUST be `https://`.
- `foundry_deployments` MUST be non-empty.
- Any future `allowed_admin_cidr` etc. variables MUST reject
  `0.0.0.0/0` per Principle V.

**No tfvars file with real values is committed to git.** The repo
ships `examples/personal.tfvars.example` and `examples/dev.tfvars.example`
with `<placeholder>` markers.

---

## 2. Terraform Outputs

Emitted by `terraform/root/outputs.tf`. Used by the operator after
apply.

| Output | What it tells the operator |
|---|---|
| `vm_tailnet_hostname` | The hostname the VM advertises on the tailnet (`tag:nemoclaw` device, e.g. `nemoclaw-3f2a.tail-scale.ts.net`) |
| `vm_resource_id` | Full Azure resource ID — useful for `az vm` commands |
| `key_vault_uri` | Where the operator pre-stages the Foundry API key + Tailscale auth key |
| `key_vault_name` | Convenience — the suffix-uniqueified name |
| `log_analytics_workspace_id` | For ad-hoc KQL queries on broker audit / NSG flow logs |
| `start_command` | A printable `az vm start ...` for the operator to copy/paste when starting the VM after auto-shutdown |

No output is `sensitive`. The Foundry API key, the Tailscale auth key,
and any other true secret are populated via `az keyvault secret set`
*outside* of Terraform.

---

## 3. Azure Resources (relationships)

```text
Resource Group (single)
├── Virtual Network (10.x.0.0/24)
│   └── Subnet "vm" (10.x.0.0/27)
│       ├── service_endpoints = ["Microsoft.KeyVault"]
│       └── NIC ── VM
├── User-Assigned Managed Identity ("nemoclaw-vm-mi")
│   └── RBAC: "Key Vault Secrets User" at scope = Key Vault resource ID
├── Key Vault
│   ├── public_network_access_enabled = false
│   ├── network_acls { default_action = "Deny", virtual_network_subnet_ids = [vm_subnet] }
│   ├── Diagnostic settings → Log Analytics (audit + metrics)
│   └── Secrets: foundry-api-key, tailscale-auth-key (placeholders)
├── Log Analytics Workspace
│   └── (Key Vault diagnostic logs only at v1 — no broker DCR)
├── Storage Account "nsgflowlogs"
│   └── NSG flow logs target
├── Network Watcher Flow Log resource
├── VM
│   ├── OS disk (platform-managed encryption)
│   ├── Boot diagnostics enabled
│   ├── User-assigned managed identity attached
│   ├── Cloud-init (custom_data) rendered from cloud-init/bootstrap.yaml.tpl
│   └── DevTest Labs auto-shutdown schedule (when var.auto_shutdown_enabled)
└── Random String "deploy_suffix" (length=4, lower+digits)
    └── Used in: KV name, storage names, MI name, anywhere with global uniqueness
```

**No public IP, no Bastion, no NSG inbound allow rules, no Private
Endpoint, no Private DNS Zone.**

---

## 4. Key Vault Secret Layout

Full schema in [contracts/kv-secret-layout.md](./contracts/kv-secret-layout.md).
Summary:

| Secret name | What it holds | Set by | Read by | Lifecycle |
|---|---|---|---|---|
| `foundry-api-key` | Foundry API key | Operator (CLI, post-apply) | Credential handoff `ExecStartPre` script via VM managed identity | Long-lived; rotated via KV update; takes effect on next `systemctl restart nemoclaw` |
| `tailscale-auth-key` | Tailscale ephemeral auth key | Operator (CLI, **before** apply) | Cloud-init via VM managed identity (before NemoClaw exists) | One-time use; the persisted KV value becomes useless after Tailscale's 24h ephemeral expiry |

Both secrets have:

- Tag `purpose` set to a stable value for documentation.
- `not-before` and `expires` set to bound the key's window.
- Diagnostic events flowing to Log Analytics (constitution requires it).

---

## 5. Credential Handoff (overview)

Full contract in [contracts/credential-handoff.md](./contracts/credential-handoff.md).
Summary:

The NemoClaw systemd unit looks roughly like:

```ini
[Service]
Type=notify
User=nemoclaw
Group=nemoclaw

# Fetch Foundry API key from Key Vault into a tmpfs file mode 0400
ExecStartPre=/usr/local/bin/nemoclaw-credential-handoff

# Consume the env var
EnvironmentFile=/run/nemoclaw/env

# Start NemoClaw with OPENAI_API_KEY in its environ
ExecStart=/usr/local/bin/openshell …

# Unlink the tmpfs file before steady state
ExecStartPost=/bin/rm -f /run/nemoclaw/env

# Hardening
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/run/nemoclaw
```

The `nemoclaw-credential-handoff` script:

1. `az login --identity` (uses VM's user-assigned managed identity).
2. `key=$(az keyvault secret show --vault-name "$KV" --name foundry-api-key --query value -o tsv)`.
3. Writes `OPENAI_API_KEY=$key` to `/run/nemoclaw/env` with `install -m 0400 -o nemoclaw -g nemoclaw`.
4. `unset key`; exits 0 (or 1 with a journald error if any step failed).

The NemoClaw host process holds `OPENAI_API_KEY` in its process
memory; the tmpfs file is gone before the service finishes startup.
The sandboxed agent never receives the env var (NemoClaw upstream's
own credential isolation).

---

## 6. On-VM Filesystem Layout

```text
/usr/local/bin/
└── nemoclaw-credential-handoff  # ExecStartPre script (root-owned, mode 0755)

/run/nemoclaw/                   # tmpfs mount, root-owned mode 0750
└── env                          # transient EnvironmentFile (mode 0400, owned nemoclaw:nemoclaw)
                                 # exists only between ExecStartPre and ExecStartPost

/var/lib/nemoclaw/               # NemoClaw's own persistent state
                                 # MUST NOT contain any value originally fetched
                                 # from Key Vault; verified by FR-009 acceptance test

/etc/systemd/system/
└── nemoclaw.service             # systemd unit with ExecStartPre + EnvironmentFile + ExecStartPost

/var/log/cloud-init.log          # cloud-init logs (Tailscale auth-key fetch path —
                                 # the auth key is scrubbed from these in-memory before write)
```

The `nemoclaw` system user runs NemoClaw. The credential handoff
script runs as root (`ExecStartPre` defaults to the unit's `User=`
unless overridden — we keep `User=nemoclaw` and use
`PermissionsStartOnly=true` only if needed; for managed identity
+ `az` access this works as the unit's user as long as the user has
a valid metadata-service path).

---

## 7. Verification entities

The post-apply verification checklist (mapped 1:1 to spec §SC-001
through SC-009) is materialised as a runnable script and a manual
checklist in [contracts/verification-checks.md](./contracts/verification-checks.md).
That file enumerates every command, the expected output, and the
acceptance criterion it satisfies.

---

## 8. State transitions

The deployment has two persistent state machines worth modeling:

**8.1. VM lifecycle**

```text
[absent] ─ terraform apply ──▶ [provisioning]
[provisioning] ─ cloud-init OK ──▶ [running]
[provisioning] ─ cloud-init fail ─▶ [running, broken]   (operator inspects via Run Command / serial console)
[running] ─ scheduled time ──▶ [deallocated]
[deallocated] ─ az vm start ──▶ [running]
[running | deallocated] ─ terraform destroy ──▶ [absent]
```

The `[running, broken]` state is intentional — at v1 we'd rather have
a broken-but-debuggable VM than a destroyed-and-redeployed one; the
operator can investigate.

**8.2. Tailscale auth key**

```text
[absent in KV] ─ operator places key ──▶ [present, unused, fresh ≤24h]
[present, unused, fresh] ─ cloud-init reads ──▶ [present, used, fresh ≤24h]
[present, used, fresh] ─ Tailscale-side 24h expiry ──▶ [present in KV, expired upstream]
[present in KV, expired upstream] ─ terraform destroy + manual node revoke ──▶ [absent]
```

FR-012's "scrub after first boot" guarantee is enforced at the
*VM* layer (cloud-init scrubs the in-memory copy from its log lines
immediately after `tailscale up`). The KV-side persistent value
becomes useless after 24h via Tailscale's own ephemeral expiry.
v2 may add a Terraform `null_resource` to purge the KV-side value
explicitly post-boot for belt-and-suspenders.
