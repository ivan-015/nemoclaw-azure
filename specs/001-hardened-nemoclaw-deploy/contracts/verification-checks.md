# Contract: Post-Apply Verification Checks

**Plan**: [../plan.md](../plan.md)
**Date**: 2026-04-25

Every check below ties to a Success Criterion in the spec. The check
includes the exact command to run, the expected result, and a pass /
fail criterion. The implementer SHOULD package these as a runnable
shell script `scripts/verify.sh` so the operator can run the full
suite after every apply.

## Pre-flight

These run before the substantive checks; if any fail, stop.

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 0a | `az` is logged in to the personal sub | `az account show --query id -o tsv` | Returns the personal sub ID |
| 0b | Tailscale client running on operator's laptop | `tailscale status --json \| jq .Self.Online` | `true` |
| 0c | Terraform state is on the remote backend | `terraform init -reconfigure` | Exits 0; no "initializing local backend" line |

## SC-002 — apply finishes ≤ 15 minutes

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 1 | Time `terraform apply -auto-approve` from start to "Apply complete" | `time terraform apply -auto-approve` | `real` ≤ 15m0s |

## SC-003 — zero open ports from a non-tailnet network

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 2a | The VM has no public IP | `az vm show -g <rg> -n <vm> --query 'publicIps' -o tsv` | empty |
| 2b | NSG has zero inbound allow rules | `az network nsg rule list -g <rg> --nsg-name <nsg> --query "[?direction=='Inbound' && access=='Allow']" -o json` | `[]` |
| 2c | Port scan from a non-tailnet host (operator's mobile hotspot) reveals nothing | `nmap -p 1-65535 --max-retries 1 -Pn <vm-public-fqdn-if-any>` | "0 hosts up" or all ports `filtered/closed` |

## SC-001 — discoverable from tailnet

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 3a | Tailscale ping succeeds | `tailscale ping <vm-tailnet-hostname>` | `pong from <vm>...` within 5 seconds |
| 3b | Tailscale SSH lands a shell (no key configured — Tailscale SSH) | `tailscale ssh <vm-tailnet-hostname> -- uptime` | Returns uptime |

## SC-004 — no secret values in the sandboxed agent's runtime surface

This is the **Principle II teeth-check**. Run from the VM (via
`tailscale ssh`).

> **Important distinction**: NemoClaw's *host* process legitimately
> has the Foundry key in its environ (that's how OpenShell receives
> it). The *sandboxed agent* must not. Per NemoClaw's docs, the
> sandbox is a separate process tree; we identify it via NemoClaw's
> documented sandbox-PID command (`nemoclaw status` or equivalent —
> the implementer documents this in `docs/THREAT_MODEL.md` once
> verified).

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 4a | Determine the sandboxed agent's PID | (NemoClaw-version-specific — placeholder: `nemoclaw status --sandbox-pid` or `pgrep -P <openshell-pid>`) | one PID |
| 4b | Tmpfs handoff file is gone after service start | `ls /run/nemoclaw/env 2>&1` | "No such file or directory" |
| 4c | Sandboxed agent's environ has no KV value | `cat /proc/<agent-pid>/environ \| tr '\0' '\n' \| grep -F "$(az keyvault secret show --name foundry-api-key --vault-name <kv> --query value -o tsv)"` | no match (exit 1) |
| 4d | Sandboxed agent's command line has no KV value | analogous against `/proc/<agent-pid>/cmdline` | no match |
| 4e | NemoClaw's persistent config dir contains no KV value | `grep -rF "$(az keyvault secret show ...)" /var/lib/nemoclaw/ /etc/nemoclaw/` | no match |

If any of 4b–4e match, **STOP**. This is a Principle II violation
and must be fixed before declaring v1 done.

## SC-005 — monthly cost target

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 5 | Forecast cost for the deployment's RG | Azure portal → Cost Management → Cost analysis, scope = the deployment's RG, timeframe = next 30 days | ≤ $40 with auto-shutdown ON; ≤ $80 PAYG |

## SC-006 — auto-shutdown fires

Run after the first scheduled shutdown time.

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 6 | VM was deallocated within 10 minutes of scheduled time | `az vm get-instance-view -g <rg> -n <vm> --query 'instanceView.statuses[?starts_with(code, '\''PowerState/'\'')].code' -o tsv` after 21:10 PT | `PowerState/deallocated` |

## SC-007 — start latency ≤ 5 minutes

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 7 | Start, then time-to-tailscale-reachable | `time (az vm start -g <rg> -n <vm> && until tailscale ping --c 1 <vm-tailnet-hostname> > /dev/null 2>&1; do sleep 5; done)` | `real` ≤ 5m0s |

## SC-008 — Key Vault audit landing

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 8 | Restart NemoClaw to trigger a fresh KV fetch, then query LA within 5 minutes | `tailscale ssh <vm> -- sudo systemctl restart nemoclaw` (record timestamp `$T`), then KQL: `AzureDiagnostics \| where ResourceProvider=='MICROSOFT.KEYVAULT' \| where OperationName=='SecretGet' \| where TimeGenerated > datetime('$T')` | one or more records, within 5 minutes |

## SC-009 — destroy + redeploy is clean

| # | Check | Command | Pass criterion |
|---|---|---|---|
| 9a | `terraform destroy -auto-approve` exits 0 | (as written) | exit code 0 |
| 9b | RG is empty after destroy | `az resource list -g <rg>` | `[]` (or RG itself is gone if `delete_resource_group` is configured) |
| 9c | Re-apply with a fresh suffix succeeds | `terraform taint random_string.deploy_suffix && terraform apply -auto-approve` | exit code 0; new KV name |

## Acceptance scenarios (User Story 1)

| # | Scenario | Check | Pass criterion |
|---|---|---|---|
| US1-1 | Single apply provisions everything with no manual intervention | (covered by SC-002) | (as above) |
| US1-2 | `tailscale ping <vm>` succeeds | (covered by 3a) | (as above) |
| US1-3 | No port responds from outside tailnet | (covered by 2c) | (as above) |
| US1-4 | NemoClaw health check responds | `tailscale ssh <vm> -- nemoclaw doctor` (or upstream's documented health command) | exit 0 |

## Edge case verifications (sample)

| # | Edge case | Check | Pass criterion |
|---|---|---|---|
| EC-1 | Auth key already-used at first boot | Pre-stage an already-used key; run apply | apply fails at cloud-init step with a journald entry citing tailscale auth failure |
| EC-2 | Foundry key rotation propagates | Rotate KV secret; trigger an inference; observe broker fetch with `cached: false` | within ≤ 5 min the broker fetches the new value |
| EC-3 | (Removed — no broker, no deny-list) | — | — |
| EC-4 | Tmpfs handoff file is unlinked promptly | After `systemctl restart nemoclaw`, run `ls -la /run/nemoclaw/env` repeatedly during 0–5 s post-restart | file exists briefly during ExecStartPre, gone within seconds |
| EC-5 | KV scope check — handoff cannot fetch tailscale-auth-key | `tailscale ssh <vm> -- sudo -u nemoclaw az keyvault secret show --vault-name <kv> --name tailscale-auth-key` | command fails (RBAC scoped to `foundry-api-key` access only via service-endpoint ACL — *or*, if RBAC is broader, `tailscale-auth-key` should be deleted from KV by then per its 24h expiry; either way the test of "handoff cannot leak Tailscale key" passes). |

## Reporting

The implementer MUST attach the verification output to the v1 PR
description:

```markdown
## Constitution & Verification Affirmation

- Constitution principles I–V reviewed; no violations.
- Verification checks 1–9, US1-1–US1-4, EC-1–EC-3 all PASS.
- Audit log sample: <link to LA query result>
- Cost forecast: $XX/mo (≤ $40 target).
- Verified NemoClaw version: <tag>.
- Region: centralus. SKU: Standard_B4als_v2.
```
