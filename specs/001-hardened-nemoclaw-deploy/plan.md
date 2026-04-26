# Implementation Plan: Hardened NemoClaw Azure Deployment (v1)

**Branch**: `001-hardened-nemoclaw-deploy` | **Date**: 2026-04-25 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/001-hardened-nemoclaw-deploy/spec.md`
**Constitution**: [v1.0.0, ratified 2026-04-25](../../.specify/memory/constitution.md)
**Reference**: [docs/IMPLEMENTATION_PLAN.md](../../docs/IMPLEMENTATION_PLAN.md)
  *(local-only operator-facing guide; this plan supersedes for code-level
  decisions but the IMPLEMENTATION_PLAN remains the high-level narrative)*

## Summary

Provision a single hardened Linux VM on Azure that runs NemoClaw for a
single personal operator. The VM has no public IP, no inbound NSG rules,
and is reachable only via the operator's Tailscale tailnet. The Foundry
API key is fetched from Key Vault on every NemoClaw service start by a
small privileged systemd `ExecStartPre` script using the VM's managed
identity; the key transits a tmpfs file with mode 0400 that the
NemoClaw service consumes via `EnvironmentFile=` and that is unlinked
before the service reaches steady state. NemoClaw upstream's own
host-vs-sandbox credential isolation guarantees the sandboxed agent
never sees the key. Non-secret Foundry configuration (endpoint URL,
deployment names, API version) lives in Terraform variables.
Auto-shutdown nightly at 21:00 America/Los_Angeles. Manual
`az vm start` is the v1 wake path. Monitoring/alerting on unexpected
downtime is deliberately out of scope for v1.

Technical approach: two-stage Terraform (a once-only `bootstrap/` for
state backend, then `root/` for everything else), Ubuntu 24.04 LTS on
`Standard_B4als_v2`, cloud-init for first-boot configuration (Tailscale
register → Docker → Node 22 → NemoClaw install + systemd unit with the
credential handoff, in that order so debug-via-tailnet remains
available even if later steps fail), NemoClaw pinned to a specific
upstream release tag.

**Note (2026-04-25)**: an earlier iteration of this plan called for a
Go-built UDS broker with peer-cred auth, per-PID caching, and a custom
journald audit pipeline. Spec clarification Q4 verified that NemoClaw's
upstream architecture (per its inference-options docs) already
intercepts inference-provider credentials on the host before they
reach the sandbox — the broker would have re-implemented protection
NemoClaw already provides. The simpler systemd `EnvironmentFile=` +
tmpfs pattern is explicitly named in constitution Principle II as a
permitted mediation channel, and audit comes from Key Vault's own
diagnostic logs (every `SecretGet` recorded by Azure). Net effect:
~16 tasks cut, ~600 lines of Go avoided, Principle II equally
satisfied.

## Technical Context

**Language/Version**:
- Terraform `>= 1.6` (`required_version` in providers.tf), `azurerm`
  provider `~> 4.x` (latest stable on apply date).
- Bash for cloud-init `runcmd` AND for the credential handoff
  `ExecStartPre` script (interpreted by `cloud-init` and `systemd`
  respectively; no separate runtime).
- `az` CLI for the credential handoff fetch (Ubuntu 24.04 with the
  Azure CLI package; managed-identity auth via `az login --identity`).
- No first-party Go service in v1.

**Primary Dependencies**:
- Azure: `azurerm` provider; user-assigned managed identity;
  `azurerm_dev_test_global_vm_shutdown_schedule` for nightly shutdown;
  Key Vault diagnostic settings → Log Analytics for audit.
- Tailscale: official Linux package from `pkgs.tailscale.com`.
- Docker: official upstream `docker-ce` repo (not Ubuntu's `docker.io`).
- Node.js 22.16+ via NodeSource.
- NemoClaw: pinned upstream release tag (`var.nemoclaw_version`).
- Azure CLI on the VM (for the credential handoff `ExecStartPre`).

**Storage**:
- Terraform state: Azure Storage backend (provisioned by `bootstrap/`,
  consumed by `root/`); `public_network_access_enabled = false`,
  `shared_access_key_enabled = false`, blob versioning ON.
- Key Vault: secrets only (Foundry API key, Tailscale auth key); RBAC
  mode; **VNet service endpoint + network ACL** (no Private Endpoint
  at v1); soft-delete + purge protection ON.
- VM disk: managed disk, platform-managed encryption.
- Log Analytics workspace: NSG flow logs, VM boot diagnostics, Key
  Vault audit (the audit trail for FR-010 / SC-008); ≥ 30-day retention.

**Testing**:
- Terraform: `terraform fmt -check`, `terraform validate`, `tflint`
  (with `azurerm` ruleset), `tfsec` for security smells.
- Shell scripts (cloud-init + credential handoff): `shellcheck`.
- Verification (post-apply, manual at v1 — automated in v2): the
  10-item checklist in spec §SC-001 → SC-009, plus the four
  acceptance scenarios of User Story 1. The Principle II tooth-check
  (SC-004) greps the *sandboxed agent* process's environ — that's
  the load-bearing security test.

**Target Platform**:
- Operator workstation: macOS or Linux with `az`, `terraform`, `gh`,
  Tailscale client.
- VM: Ubuntu 24.04 LTS (Azure Marketplace image
  `Canonical:ubuntu-24_04-lts:server:latest`, pinned in Terraform).
- Region: `centralus` default, override via `var.location`.
- SKU: `Standard_B4als_v2` default (4 vCPU / 8 GB AMD burstable;
  exact match for NemoClaw's verified upstream minimum; ~$60/mo
  PAYG, ~$32/mo with the v1 nightly shutdown).

**Project Type**:
- Infrastructure-as-code (Terraform) + cloud-init shell scripts +
  systemd unit definitions. Not a web app, library, CLI, or compiler.
  No first-party long-running service (the credential handoff is a
  one-shot `ExecStartPre` script). The deliverable is a working
  `terraform apply` and the supporting scripts/units that apply
  installs.

**Performance Goals**:
- Time-to-deploy ≤ 15 min from start of `apply` (SC-002).
- Time from `az vm start` to Tailscale-reachable + service-healthy
  ≤ 5 min (SC-007).
- Credential handoff `ExecStartPre` ≤ 5 s wall-clock (KV round trip
  + tmpfs write); only runs on service start, not per inference.
- 100% audit-record landing in Log Analytics within 5 min of the KV
  read (SC-008).

**Constraints**:
- **Principle II is non-negotiable**: no NemoClaw-reachable
  surfacing of any secret value, ever, in env / argv / config /
  persisted log.
- **Zero inbound network**: no public IP, no NSG inbound allow rules,
  no Bastion, no SSH-via-public.
- **Cost ceiling**: ≤ $40/mo with auto-shutdown; ≤ $80/mo PAYG.
- **No Terragrunt at v1** (constitution Principle V).
- **Deploy-time-unique resource naming** for resources subject to
  soft-delete (Key Vault — see FR-026) so destroy/redeploy doesn't
  block.

**Scale/Scope**:
- 1 VM, 1 operator, 1 environment. No multi-tenancy. No HA. No
  multi-region. v1 is intentionally minimum-viable so iteration is
  fast and the security surface is auditable in one sitting.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle / Constraint | v1 Plan Compliance | Notes |
|---|---|---|
| **I. Security as Default** — NSG default-deny, no public SSH, hardened sandbox preserved, disk encryption, managed identity | ✅ PASS | Zero NSG inbound rules; Tailscale qualifies as "or equivalent" admin path under Principle I's clause; managed identity used for KV access; platform-managed disk encryption ON; NemoClaw sandbox shipped as upstream provides. |
| **II. Secrets Never Touch the Agent's Environment (NON-NEGOTIABLE)** | ✅ PASS | Foundry API key fetched from KV via managed identity at NemoClaw service startup (FR-007); transits a tmpfs file mode 0400 unlinked before steady state (FR-008) — a pattern Principle II *explicitly* names as permitted. NemoClaw upstream's host-vs-sandbox isolation guarantees the sandboxed agent never receives the key (FR-009). KV reachable only from the deployment's VNet via service endpoint + network ACL (FR-014). Audit via Key Vault diagnostic logs to Log Analytics (FR-010). Tailscale auth key follows the same managed-identity-fetch pattern but at first boot only, scrubbed from cloud-init logs (FR-012). |
| **III. Least Privilege Everywhere** | ✅ PASS | Managed identity granted only `Key Vault Secrets User` at the KV scope (not subscription); KV public access OFF; storage public access OFF; no `*` source on any rule (no rules); Key Vault RBAC mode. |
| **IV. Cost-Conscious by Default** — `Standard_B4ms` named as target, ≤ $130/mo, auto-shutdown opt-in | ⚠ DEVIATION (justified, see below) | We use `Standard_B4als_v2` (4/8 AMD) instead of the constitution's named `Standard_B4ms` (4/16). NemoClaw's upstream README (verified 2026-04-25) sets the minimum at 4 vCPU / 8 GB, not 4/16. B4als_v2 exactly matches the verified minimum at the lowest available price point (~$60/mo PAYG vs B4ms's ~$120/mo). This is *strictly cheaper, equally hardened*, and consistent with the constitution's own clause "cheaper SKUs are preferred when NemoClaw runs cleanly on them." Recommend a future PATCH-level constitution amendment to update the named example to reflect the 8 GB upstream reality. |
| **V. Reproducible & Auditable** — Terraform with pinned providers, remote backend, validation blocks, no Terragrunt, NemoClaw release-tag pin | ✅ PASS | Two-stage Terraform (`bootstrap/` → `root/`); `azurerm` pinned `~> 4.x`, NemoClaw version is a Terraform variable; `*.tfvars.example` files only (no real tfvars committed); KV data sources at apply time for any value the operator pre-stages. |
| **Security Constraints — NSG, Storage, KV, Diag, Disk, Threat Model, no hardcoded sensitive values** | ✅ PASS | All checked above; threat model written in Phase 1 of this plan (`docs/THREAT_MODEL.md`). |
| **Cost & Operational Constraints — tags, ≤ $130/mo, hourly-minimum opt-in, region default, auto-shutdown opt-in** | ✅ PASS w/ note | Four mandatory tags applied to every resource; default profile cost ≤ $40/mo with auto-shutdown (well under $130 ceiling). Region default `centralus` instead of `eastus2` — README will document the deviation per the constitution's "user-overridable" clause; this is a permitted override, not a violation. |

**Gate result**: ✅ PASS. The single deviation (Principle IV named SKU)
is justified by post-constitution upstream verification and is in the
*more* cost-conscious direction than the constitution's named example.
Logged under Complexity Tracking below.

## Project Structure

### Documentation (this feature)

```text
specs/001-hardened-nemoclaw-deploy/
├── plan.md                       # This file
├── research.md                   # Phase 0 output
├── data-model.md                 # Phase 1 output (Terraform vars/outputs, KV layout, on-VM filesystem)
├── quickstart.md                 # Phase 1 output (operator-facing setup guide)
├── contracts/
│   ├── credential-handoff.md     # systemd ExecStartPre + tmpfs + EnvironmentFile contract
│   ├── tfvars-inputs.md          # Module-level variable contract
│   ├── kv-secret-layout.md       # Key Vault secret naming + access policy
│   └── verification-checks.md    # Post-apply verification commands & expected results
├── tasks.md                      # /speckit-tasks output
└── checklists/
    └── requirements.md           # Already created by /speckit-specify
```

### Source Code (repository root)

```text
terraform/
├── bootstrap/                    # Run once with local state
│   ├── main.tf                   # RG + storage account + container for state
│   ├── variables.tf
│   ├── outputs.tf                # Emits backend config block for `root/`
│   ├── providers.tf
│   └── README.md                 # Recovery path, refresh-only re-run docs
├── root/                         # All subsequent applies; remote backend
│   ├── main.tf                   # Module composition entry point
│   ├── variables.tf              # All operator-facing inputs
│   ├── outputs.tf                # tailnet hostname, KV URI for secret population
│   ├── providers.tf              # Azurerm + backend block
│   ├── locals.tf                 # Mandatory tags + derived names + deploy-stamp
│   ├── modules/
│   │   ├── network/              # VNet + subnet + NSG (zero ingress rules) + KV service-endpoint config
│   │   ├── identity/             # User-assigned managed identity + RBAC
│   │   ├── keyvault/             # KV + service endpoint + network ACL + secret placeholders
│   │   ├── log-analytics/        # Workspace + diag settings + flow logs
│   │   └── vm/                   # VM, NIC, OS disk, cloud-init template, shutdown schedule
│   └── examples/
│       ├── personal.tfvars.example   # Default profile (auto-shutdown ON)
│       └── dev.tfvars.example        # Auto-shutdown OFF for active iteration
├── cloud-init/
│   ├── bootstrap.yaml.tpl        # Terraform-templated cloud-init
│   └── scripts/                  # Bash helpers invoked from cloud-init
│       ├── 01-tailscale.sh           # Fetch + register + scrub Tailscale auth key
│       ├── 02-docker.sh              # Pinned Docker CE install
│       ├── 03-node.sh                # Node 22.16+ via NodeSource
│       ├── 04-credential-handoff.sh  # ExecStartPre script — fetch Foundry key, write to tmpfs
│       ├── 05-nemoclaw.sh            # NemoClaw install (pinned tarball, unattended)
│       └── nemoclaw.service.tpl      # systemd unit with EnvironmentFile=/run/nemoclaw/env
├── docs/
│   ├── IMPLEMENTATION_PLAN.md   # Pre-existing; high-level narrative (local-only)
│   ├── THREAT_MODEL.md          # NEW (Phase 1) — required by constitution Security Constraints
│   └── TAILSCALE.md             # NEW (Phase 1) — auth-key lifecycle + ACL recommendations
└── README.md                    # NEW (Phase 1) — happy path + region trade-off note (constitution req)
```

Note: `04-credential-handoff.sh` is a small shell script invoked as
`ExecStartPre` for the NemoClaw systemd unit, not a separately
installed service. `nemoclaw.service` is a Terraform-templated unit
file dropped under `cloud-init/` and copied into place during boot.

**Structure Decision**: The codebase is **infrastructure-first with a
thin scripts layer (cloud-init + systemd units)**. Terraform holds
the bulk of the work; cloud-init + a small `ExecStartPre` script is
the only first-party runtime code, and it's shell, not Go. This
rejects the template's "single project" / "web app" / "mobile"
options because none of them fit. The chosen structure mirrors the
agency-os infrastructure layout the operator already uses (separate
`bootstrap/` and `root/`, modules under `root/modules/`) for cognitive
familiarity, while staying intentionally flatter (no Terragrunt; one
environment; no first-party Go service).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| **Principle IV's named default SKU (`Standard_B4ms`) replaced with `Standard_B4als_v2`** | Upstream NemoClaw README (verified 2026-04-25) lists 4 vCPU / 8 GB / 20 GB as the minimum, not the 16 GB the constitution assumed at ratification. B4als_v2 exactly matches that minimum on AMD-burstable hardware at ~50% the price of B4ms. The constitution itself permits "cheaper SKUs ... when NemoClaw runs cleanly on them," which this is. | Sticking with B4ms means paying for 8 GB of RAM the agent never touches (~$60/mo extra, doubled cost), with no security or capability benefit. Sticking with the smaller `Standard_B2ms` (2/8) would undersize CPU below the verified minimum. |
| **Region default `centralus`** instead of constitution's `eastus2` | Operator's existing personal-adjacent infrastructure is already in `centralus`; co-location simplifies networking discoverability and Tailscale routing. The constitution's *Cost & Operational Constraints* explicitly permits the operator to override the region default; the README will document the trade-off as required. | `eastus2` would split the operator's footprint across two regions for no functional benefit. |
| **Key Vault VNet service endpoint instead of Private Endpoint** | Constitution Security Constraints names PE as the preferred pairing for `public_network_access_enabled = false` "when network design allows." Single-VM, single-consumer scenarios meet the same intent (KV unreachable from public internet, only via VNet) at zero marginal cost without PE's overhead (Private DNS Zone, virtual-network link, A record). Research R13 documents the call. v2 upgrade trigger: when this deployment grows beyond a single VNet/consumer, switch to PE. | PE adds ~$7/mo plus 3+ Terraform resources (private DNS zone, vnet link, A record, the PE itself) for no security delta in the single-consumer case. |

These three items are deviations of *named example*, not of *intent*.
Recommend a PATCH-level constitution amendment after first deploy to:
(1) update the named SKU example to reflect the verified upstream
8 GB minimum, and (2) clarify that "Private Endpoint when network
design allows" admits VNet service endpoints as an equivalent pattern
in single-consumer scenarios. The region clause already accommodates
that override case.
