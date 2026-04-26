# Feature Specification: Hardened NemoClaw Azure Deployment (v1)

**Feature Branch**: `001-hardened-nemoclaw-deploy`
**Created**: 2026-04-25
**Status**: Draft
**Input**: User description: "Deploy a single hardened Linux VM running
NemoClaw on Azure for personal, single-operator use. Tailscale-only access,
no public ingress, brokered secrets per Principle II of the project
constitution, Azure AI Foundry as inference provider, auto-shutdown for
cost control."

## Clarifications

### Session 2026-04-25

- Q: When the VM is unexpectedly down (crash, host maintenance reboot,
  OOM, service crash) outside the planned auto-shutdown window, should
  v1 notify the operator? → A: No — discover-on-next-use is acceptable
  for personal single-operator scope. No Azure Monitor alert rules, no
  Action Groups, no email/SMS routing in v1. Operator finds out when
  Tailscale ping or NemoClaw health check fails on next use; manual
  recovery via `az vm start` and `journalctl`. Monitoring/alerting is
  v2 backlog.
- Q: Should non-secret Foundry configuration (endpoint URL, deployment
  name, API version) flow through Key Vault and the broker, or live in
  Terraform variables? → A: Secrets-only Key Vault. Key Vault stores
  only the Foundry API key and the Tailscale auth key. The endpoint
  URL, model deployment name(s), and API version are Terraform input
  variables, passed via cloud-init into NemoClaw's config file. The
  broker only ever serves the Foundry API key at runtime. Deployment
  name supports single or multiple models via a list/map variable.
  Rationale: smaller broker surface area; broker is for the things
  Principle II is protecting (long-lived secrets), not for non-secret
  config; tfvars makes config changes diff-reviewable.
- Q: Is broker-side caching of fetched secrets permitted, or must every
  fetch hit Key Vault? → A: Caching is permitted under strict
  constraints — in-memory only (never on disk), scrubbed on broker
  restart, every cache miss audited identically to a fresh fetch,
  rotation propagates within the bounded cache lifetime. The spec does
  NOT lock in a specific caching algorithm; the plan phase selects
  among candidates (time-based TTL ≤30s, per-caller-PID lifetime,
  KV-version-metadata refresh, etc.). Rationale: caching does not
  weaken Principle II (the broker necessarily holds the secret in
  memory transiently regardless), reduces Key Vault read load, and
  reduces audit-log noise without sacrificing accountability.
  **2026-04-25 LATER**: this question became moot when Q4 replaced the
  broker entirely with a one-shot startup handoff. The broker-caching
  decision recorded here was correct *if* a runtime broker were the
  design; with the simpler design no cache exists. Preserved here for
  audit trail.
- Q: Given that NemoClaw's own architecture intercepts inference-
  provider env vars on the host BEFORE the sandboxed agent sees them
  (per upstream documentation: *"Provider credentials stay on the host.
  The sandbox does not receive your API key."*), is a runtime UDS
  broker on the VM actually adding security value, or is it
  re-implementing protection NemoClaw already provides? → A: The broker
  re-implements existing NemoClaw protection. **Drop the runtime broker
  entirely.** Replace with a one-shot startup handoff that uses the
  *same* JIT-tmpfs pattern explicitly named in constitution Principle
  II: at NemoClaw service startup, a small privileged script fetches
  the Foundry API key from Key Vault using the VM's managed identity,
  writes it to a tmpfs file with mode 0400, NemoClaw's host process
  consumes it via systemd `EnvironmentFile=`, and the file is unlinked
  before NemoClaw reaches the steady state. The sandboxed agent never
  sees the key (NemoClaw's own design enforces this). Rotation
  requires a `systemctl restart nemoclaw` rather than a broker cache
  invalidation — acceptable for personal single-operator use. Audit
  trail comes from Key Vault's own diagnostic logs (every secret read
  is recorded by Azure with timestamp + identity), not a custom broker
  audit emitter. Net effect: ~16 tasks cut, ~600 lines of Go avoided,
  Principle II still satisfied through the constitution's other named
  example pattern. Trade-off accepted: marginally less defense-in-depth
  on the host process (the host still has the key in its environ for
  its lifetime), but this is exactly what NemoClaw's own design treats
  as acceptable.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Stand up a working, reachable NemoClaw from a fresh clone (Priority: P1)

The operator clones the repository onto a fresh machine, supplies a small
set of inputs (Azure subscription, Foundry credentials, Tailscale auth
key), runs the documented bootstrap and apply sequence, and ends up with
a NemoClaw instance running on Azure that they can reach from their
laptop over their Tailscale network — without any port being exposed to
the public internet.

**Why this priority**: This is the entire point of the project. Without
this end-to-end happy path, no other capability matters. It is also the
single most observable measure of success — either the operator can use
NemoClaw or they cannot.

**Independent Test**: From a fresh clone on a clean machine: configure
the inputs, run the bootstrap and apply, then from a Tailscale-joined
laptop confirm `tailscale ping <vm>` succeeds and the NemoClaw service
responds to its health check. No other story needs to be implemented for
this test to be meaningful.

**Acceptance Scenarios**:

1. **Given** a fresh clone of the repository and a configured personal
   Azure subscription, **When** the operator follows the documented
   apply sequence end-to-end, **Then** the entire stack provisions in
   one apply with no manual intervention required during the apply.
2. **Given** the deployment has completed, **When** the operator runs
   `tailscale ping <vm-hostname>` from their tailnet-joined laptop,
   **Then** the ping succeeds within seconds.
3. **Given** the deployment has completed, **When** the operator
   attempts to reach any port on the VM from a non-tailnet network
   (e.g. a mobile hotspot), **Then** every connection attempt fails (no
   port responds).
4. **Given** the deployment has completed, **When** the operator runs
   NemoClaw's install-integrity self-check (`nemoclaw doctor` or
   upstream's documented equivalent) over the tailnet, **Then** it
   exits 0. *Note*: at the US1 boundary the systemd unit is enabled
   but not started — the service starts in US2 once the credential
   handoff is wired in. "Service reports healthy" at US1 means
   "install-integrity check passes," not "systemd `active (running)`".

---

### User Story 2 — Sandboxed agent never sees a static secret (Priority: P1)

NemoClaw, running inside its sandbox, calls Azure AI Foundry to perform
inference. The Foundry API key reaches NemoClaw's *host* process via a
just-in-time tmpfs handoff at service startup (per the constitution
Principle II's named pattern); NemoClaw's own architecture then
guarantees the *sandboxed agent* never receives the key. The secret
never appears in the agent's environment, command line, or anything
the agent can read on disk.

**Why this priority**: Non-negotiable per Principle II of the
constitution. The whole reason this project exists is that a
prompt-injected agent must not be able to exfiltrate long-lived
secrets by reading its own environment. NemoClaw upstream already
implements host-vs-sandbox credential isolation; this project's job
is to make sure the host-side credential never came from a
filesystem-stored or tfvars-stored value — it came from Key Vault via
managed identity, transited through a tmpfs file deleted before the
service reached its steady state.

**Independent Test**: With NemoClaw running, the operator (1) runs a
real inference operation and observes it succeed, (2) prints the
*sandboxed agent* process's environment via `cat /proc/<agent-pid>/environ`
and confirms no Foundry-key value appears, (3) inspects the
deployment's `/run/nemoclaw/` directory and confirms the tmpfs
handoff file no longer exists, and (4) confirms the Key Vault
diagnostic logs in Log Analytics record the managed-identity-driven
secret fetch.

**Acceptance Scenarios**:

1. **Given** the Foundry API key is stored in Key Vault and the
   NemoClaw systemd service is configured to fetch it via the VM's
   managed identity, **When** the service starts, **Then** the key
   passes through a mode-0400 tmpfs file owned by the NemoClaw host
   user, is consumed via `EnvironmentFile=`, and the file is unlinked
   before the service finishes startup.
2. **Given** NemoClaw is running, **When** the operator examines the
   sandboxed agent process's environment variables, command-line
   arguments, and on-disk configuration, **Then** no inference-provider
   secret value appears in any of them.
3. **Given** the deployment fetches the Foundry API key from Key Vault
   on each NemoClaw service start, **When** the operator queries Key
   Vault diagnostic logs in Log Analytics, **Then** every secret-read
   event appears with its identity, timestamp, and result code within
   minutes.
4. **Given** the Foundry API key has been rotated in Key Vault,
   **When** the operator restarts the NemoClaw systemd service,
   **Then** the new key is picked up on the next inference call without
   redeploying the VM.

---

### User Story 3 — Cost stays inside the personal-budget envelope (Priority: P2)

The operator does not have to actively manage the deployment to keep
costs low. The instance is automatically powered down outside working
hours so that idle time is not billed at full compute rate, and the
operator can review the verified monthly cost against a stated target
before deciding to commit further.

**Why this priority**: This is a personal project with a personal
budget. Without cost controls the operator either over-pays or
remembers to manually shut things down — both are failure modes.
P2 because the deployment is technically usable without auto-shutdown,
just more expensive.

**Independent Test**: After the first night of operation, the operator
can confirm via Azure activity log that the VM was deallocated at the
configured local time, and can confirm via Azure cost reporting that
the projected monthly run-rate matches the stated target.

**Acceptance Scenarios**:

1. **Given** the deployment is in its default profile, **When** the
   configured shutdown time arrives in the configured timezone, **Then**
   the VM is automatically deallocated.
2. **Given** the VM is deallocated, **When** the operator wants to use
   NemoClaw again, **Then** they can start the VM with a single
   documented command and reach the service over Tailscale within a
   small number of minutes.
3. **Given** the deployment has been running for a full billing cycle
   under the default profile, **When** the operator reviews monthly
   cost, **Then** the total falls inside the documented target band.

---

### User Story 4 — Operator can debug a broken deployment without exposing the network (Priority: P2)

When something on the VM is misbehaving — a service won't start, a log
needs to be read, a config needs to be re-applied — the operator can
investigate and remediate without opening any port to the public
internet, even if Tailscale itself is not yet up.

**Why this priority**: A deployment that can only be debugged by
opening SSH to the world or by destroying and re-creating is brittle.
P2 because it is a maintenance affordance, not the primary user value.

**Independent Test**: With the VM running and Tailscale intentionally
disabled, the operator can still execute a script on the VM and read
its output, and can still attach to the boot console, using only Azure
control-plane authenticated paths.

**Acceptance Scenarios**:

1. **Given** the VM is running but Tailscale is unhealthy, **When** the
   operator wants to inspect a system log or restart a service, **Then**
   they can do so via an Azure-control-plane mechanism that does not
   require any inbound network port on the VM.
2. **Given** networking on the VM is fully broken, **When** the
   operator wants to see what the boot is doing, **Then** they can
   attach to a console session via the Azure portal.

---

### User Story 5 — A `terraform destroy` leaves no residue that blocks the next deploy (Priority: P3)

When the operator decides to tear down the deployment — to start over,
to test a change, to stop incurring cost — `terraform destroy` removes
everything it provisioned, and a subsequent fresh `apply` is not
blocked by leftovers from the previous deploy.

**Why this priority**: Critical for iteration speed during development
of this project itself, less critical at steady state. P3 because the
operator can work around residue with naming changes — but it makes
the project frustrating.

**Acceptance Scenarios**:

1. **Given** a successful apply, **When** the operator runs `terraform
   destroy`, **Then** every Azure resource the apply created is
   removed.
2. **Given** purge protection is enabled on the Key Vault (constitution
   requirement), **When** the operator wants to redeploy after a
   destroy, **Then** the documented re-deploy path does not require
   waiting out the soft-delete retention window.

---

### Edge Cases

- **Tailscale auth key is expired or already-consumed at first boot**:
  The deployment must fail loudly during cloud-init, surface the cause
  to the operator via the Azure boot diagnostics, and not leave a
  half-configured VM in an unrecoverable state.
- **Foundry key is invalid or rotated mid-operation**: NemoClaw's
  inference call must fail with a clear error. The operator updates
  the secret in Key Vault and runs `systemctl restart nemoclaw` on
  the VM (via Tailscale SSH or Run Command); the new key is picked up
  on next inference call. Re-deploying the VM is not required.
- **Foundry endpoint URL or deployment name changes**: because these
  live in Terraform variables (not Key Vault), changing them requires
  a `terraform apply`. Acceptable trade-off for personal scope; if
  rotating Foundry instances frequently becomes a real workflow,
  revisit in v2.
- **The configured Azure region lacks quota for the chosen VM SKU**:
  The apply must fail at plan or early-apply time with a
  human-readable message — never partially succeed.
- **Operator's Tailscale account/tailnet is unavailable** (Tailscale
  outage, account suspension): The VM must continue running
  NemoClaw's existing work; the operator must be able to use the
  Azure-control-plane debug paths to confirm the situation; the
  operator must not be permanently locked out of admin operations.
- **NemoClaw's installer changes its prompt sequence** between the
  pinned upstream version and a newer release: The deployment must
  remain reproducible at the pinned version; an explicit upgrade
  action is the only way the version moves.
- **Auto-shutdown fires while NemoClaw is mid-task**: This is
  acceptable for personal use; the next start should resume cleanly
  rather than leave NemoClaw in a broken state.
- **Operator forgets to start the VM and tries to use NemoClaw**: The
  failure mode must be obvious (Tailscale ping fails) and the recovery
  must be documented (one-line `az vm start`).

## Requirements *(mandatory)*

### Functional Requirements

**Network access model**

- **FR-001**: System MUST provision the VM with no public IP address.
- **FR-002**: System MUST configure the VM's network security group with
  zero inbound allow rules; the only inbound rule permitted is the
  default deny.
- **FR-003**: System MUST configure the VM as a node on the operator's
  Tailscale tailnet on first boot, using a one-time auth key supplied
  out-of-band, so that admin and service access flow exclusively over
  the tailnet.
- **FR-004**: System MUST restrict the VM's outbound traffic to a stated
  allowlist (Azure AD, Key Vault, Storage, container registries,
  Tailscale coordination/relay, Azure AI Foundry, OS/runtime update
  servers); any other outbound destination MUST be denied.
- **FR-005**: System MUST NOT provision any SSH-key infrastructure, and
  MUST NOT provision an Azure Bastion.
- **FR-006**: System MUST keep the Azure-control-plane debug paths
  (Run Command, serial console) functional independently of any inbound
  network rule.

**Secret handling (constitution Principle II — non-negotiable)**

- **FR-007**: System MUST fetch the Foundry API key from Key Vault on
  every NemoClaw service start, using the VM's user-assigned managed
  identity. The fetch MUST happen via a privileged startup script that
  the sandboxed agent cannot read or invoke.
- **FR-008**: The fetched Foundry API key MUST be surfaced to NemoClaw
  exclusively via a tmpfs file (in-memory filesystem, not on disk)
  with mode 0400, owned by the NemoClaw host user, consumed via
  systemd `EnvironmentFile=`, and unlinked before NemoClaw's service
  reaches steady state.
- **FR-009**: The Foundry API key MUST NOT be present in the
  *sandboxed agent process's* environment, command-line arguments,
  on-disk configuration, or any persisted log. NemoClaw upstream
  guarantees this via its host-vs-sandbox credential isolation; this
  project verifies it via the SC-004 tooth-check.
- **FR-010**: All secret accesses (Key Vault `SecretGet` operations
  by the VM's managed identity) MUST be logged to Log Analytics via
  Key Vault's diagnostic settings. The audit record (which secret,
  which identity, when, success/failure) MUST be queryable within
  minutes of the access.
- **FR-011**: The Foundry API key MUST be the *only* secret that the
  NemoClaw service's startup script fetches. Any expansion of the
  fetched-secret list (e.g., adding telemetry tokens) requires a
  spec amendment so the threat model can be re-evaluated.
- **FR-012**: The Tailscale auth key, used only at first boot, MUST be
  fetched directly from Key Vault by cloud-init (operator-trusted code
  running with elevated privileges before NemoClaw exists), used once,
  and scrubbed from cloud-init logs. It MUST NOT be reachable by
  NemoClaw at any time. The key's natural Tailscale-side expiry (24h
  ephemeral) is the v1 mitigation against the residual KV-stored
  copy; explicit KV-side purge is a v2 nicety.

**Secret store**

- **FR-013**: System MUST use Azure Key Vault as the source of truth for
  *true secrets* needed by the deployment. v1 Key Vault contents:
  Foundry API key, Tailscale auth key (one-time use). Non-secret
  Foundry configuration (endpoint URL, deployment name(s), API version)
  MUST be supplied via Terraform input variables, not Key Vault.
- **FR-014**: The Key Vault MUST have public network access disabled
  AND MUST be reachable only from inside the deployment's virtual
  network. v1 achieves this via a VNet **service endpoint** plus a
  network ACL allowing only the deployment's `vm` subnet; the
  service-endpoint approach is zero marginal cost compared to a
  Private Endpoint. Private Endpoint is a v2 upgrade option once
  multi-VNet or multi-consumer scenarios apply.
- **FR-015**: The Key Vault MUST have soft-delete and purge protection
  enabled, and MUST use role-based access control (not access policies).
- **FR-016**: The VM MUST authenticate to Key Vault using a
  user-assigned managed identity scoped to the *minimum* role required
  to read the specific secrets it needs — no broader.

**Deployment ergonomics**

- **FR-017**: System MUST provision the entire deployment in a single
  `terraform apply` from a fresh clone, given a one-time
  state-backend bootstrap step is already complete.
- **FR-018**: System MUST require no manual interaction *during a
  single `terraform apply` invocation* (no interactive installers, no
  prompts, no manual configuration steps mid-apply). Operator actions
  *between* applies — specifically the documented two-stage flow where
  Key Vault is created first, the operator seeds the Foundry API key
  and Tailscale auth key, then the full apply finishes — are
  explicitly permitted and counted as one-time procurement, not
  mid-apply intervention.
- **FR-019**: System MUST pin the NemoClaw release to a single,
  operator-supplied version identifier, so that two applies with the
  same inputs produce the same NemoClaw version.
- **FR-020**: System MUST tag every Azure resource it provisions with
  the four mandatory tags defined in the project constitution.

**Cost & operations**

- **FR-021**: System MUST deallocate the VM automatically each day at
  the operator-configured local time and timezone (default 21:00
  America/Los_Angeles).
- **FR-022**: System MUST allow the operator to start the VM again on
  demand using a documented one-line command from their workstation.
- **FR-023**: System MUST send VM, Key Vault, and NSG-flow diagnostic
  logs to a central Log Analytics workspace with at least 30-day
  retention.
- **FR-024**: System MUST enable disk encryption on the VM.

**Cleanup**

- **FR-025**: `terraform destroy` MUST remove every resource the apply
  created, including dependents that were not directly named in the
  module (e.g. auto-created NICs, public IPs if any, OS disks).
- **FR-026**: The deployment MUST be re-deployable after a destroy
  without waiting out the Key Vault soft-delete retention window
  (achieved via deploy-time-unique resource naming, documented in the
  README).

**Documentation**

- **FR-027**: System MUST ship a documented threat model that lists
  assets, attackers, mitigations, and residual risks, and that names
  NemoClaw upstream's host-vs-sandbox credential isolation (combined
  with this deployment's just-in-time tmpfs handoff at startup) as
  the principal mitigation for the prompt-injection exfiltration
  threat.
- **FR-028**: System MUST ship a documented happy path so that an
  external engineer can follow it and reach a working deployment
  without the original author's help.

### Key Entities

- **NemoClaw host process**: The on-VM service (run by systemd) that
  hosts the inference gateway and spawns the sandboxed agent. Receives
  the Foundry API key via systemd `EnvironmentFile=` at startup;
  isolates the key from the sandbox per NemoClaw's own architecture.
- **Sandboxed agent**: The LLM-driven process spawned inside NemoClaw's
  Landlock + seccomp + namespace sandbox. Never receives the Foundry
  API key. This is the threat surface Principle II is protecting.
- **Credential handoff script**: A small privileged shell script run as
  systemd `ExecStartPre` for the NemoClaw service. Fetches the Foundry
  API key from Key Vault using the VM's managed identity, writes it to
  a tmpfs file with mode 0400, and lets `EnvironmentFile=` consume it.
  An `ExecStartPost` step unlinks the tmpfs file before the service
  reaches steady state.
- **Key Vault**: Single Azure-side source of truth for *true secrets*
  used by the deployment (Foundry API key, Tailscale auth key).
  Non-secret Foundry config lives in Terraform variables, not here.
  Reachable only from the deployment's VNet via a service endpoint
  plus a network ACL.
- **Tailnet**: The operator's existing Tailscale mesh network. The VM
  joins it on first boot and is reachable only via it for both admin
  and service traffic.
- **Foundry endpoint**: Operator's existing Azure AI Foundry
  (OpenAI-compatible) inference endpoint, located in a separate
  subscription, accessed using a key scoped only to this deployment.
  The endpoint URL, deployment name(s), and API version are supplied
  via Terraform variables; only the API key flows through Key Vault
  and the credential handoff.
- **State backend**: An Azure Storage account (provisioned in a one-
  time bootstrap stage) that holds Terraform state for all subsequent
  applies, with public access disabled and locking enabled.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator who has never seen the repository before can
  follow the documented happy path on a fresh laptop and reach a working
  NemoClaw via Tailscale in under 30 minutes of wall-clock time
  (excluding any one-time Azure subscription, Tailscale account, or
  Foundry-key procurement).
- **SC-002**: Once apply has started, the deployment finishes provisioning
  in 15 minutes or less without any manual intervention.
- **SC-003**: A scan of every port on the VM from a non-tailnet network
  returns zero open ports, every time.
- **SC-004**: An inspection of the *sandboxed agent process's*
  environment, command line, and on-disk configuration after a
  successful inference call returns zero matches against any value
  stored in Key Vault. (NemoClaw's host process may legitimately have
  the key in its environ; the agent must not.)
- **SC-005**: Verified monthly Azure cost for the default deployment
  profile (with auto-shutdown applied for the configured hours) is
  $40 or less; pay-as-you-go cost without auto-shutdown is $80 or
  less.
- **SC-006**: After the auto-shutdown time, the VM is in the
  deallocated state within 10 minutes (Azure's documented dispatch
  window).
- **SC-007**: From issuing the start command to the VM being reachable
  again over Tailscale is 5 minutes or less, on the chosen SKU.
- **SC-008**: 100% of Key Vault `SecretGet` operations by the VM's
  managed identity land in Log Analytics within 5 minutes of the
  fetch (Azure's standard diagnostic-log dispatch window).
- **SC-009**: A `terraform destroy` followed immediately by a
  `terraform apply` (with the documented per-deploy naming step)
  succeeds without manual cleanup of soft-deleted Key Vault objects.

## Assumptions

- **Single operator, single tenant**: This deployment serves exactly one
  human user. No multi-user authentication, no tenant separation, no
  per-user secret scoping is required at v1.
- **Personal Azure subscription**: A dedicated Azure subscription, not
  shared with any production workload, is available before deployment
  begins. The operator has Owner or equivalent rights at the
  subscription scope so role assignments and provider registrations
  succeed without escalation.
- **Pre-existing Tailscale account**: The operator already runs a
  Tailscale tailnet for personal use. They can issue a reusable,
  ephemeral, pre-approved auth key and place it in Key Vault before
  the first apply.
- **Pre-existing Foundry endpoint**: The operator already operates an
  Azure AI Foundry instance (in a separate subscription) that exposes
  an OpenAI-compatible endpoint. They can issue a separate key for
  this deployment that is *not* the production key.
- **Region default `centralus`**: This region is selected based on
  parity with the operator's existing personal infrastructure. The
  region is configurable.
- **VM SKU default `Standard_B4als_v2`**: This SKU exactly matches
  NemoClaw's verified upstream minimum (4 vCPU / 8 GB / 20 GB) on
  AMD-burstable hardware at lowest cost. The SKU is configurable.
- **Bootstrap stage runs once per subscription**: A short, one-time
  Terraform stage stands up the state-backend storage account; this
  stage uses local state, runs once, and is documented separately from
  the main apply.
- **Operator is responsible for procuring the Tailscale auth key, the
  Foundry key, and the Foundry endpoint URL** before the first apply.
  The deployment will fail loudly if any of these are missing rather
  than hiding the failure.
- **NemoClaw at v1 has no documented unattended-install path**
  (verified against the upstream README on 2026-04-25). Achieving
  unattended install is an open implementation problem to be solved
  during planning; the spec does not mandate the mechanism, only the
  outcome (FR-018).
- **Inference is the only NemoClaw external dependency at v1**. If
  NemoClaw needs additional outbound endpoints (telemetry, sandbox
  image registries, etc.), those will be discovered during the
  research phase of planning and added to the egress allowlist.
- **Auto-start is manual at v1**. The operator runs `az vm start`
  themselves when they want to use NemoClaw; automated wake-up is
  v2.

## Out of Scope (v1)

- Customer-managed encryption keys for disk or Key Vault.
- Private Endpoint for Key Vault or for the state Storage account
  (v1 uses VNet service endpoints + network ACLs — same "no public
  reachability" guarantee at zero marginal cost; PE is v2 once
  multi-VNet scenarios apply).
- Custom UDS-based runtime credential broker (considered, then
  rejected once we verified NemoClaw's own host-vs-sandbox isolation
  already provides the protection a broker would have added). The
  v1 design uses systemd `EnvironmentFile=` with a tmpfs file —
  also explicitly named in constitution Principle II.
- Pre-baked Packer images (cloud-init is the v1 mechanism).
- Automated VM start (manual `az vm start` is v1).
- Automated Tailscale auth-key rotation (manual rotation is v1).
- Explicit Key-Vault-side purge of the consumed Tailscale auth key
  (v1 relies on the key's natural 24h Tailscale-side expiry; v2 may
  add a Terraform `null_resource` purge for belt-and-suspenders).
- Multi-environment dev/prod split.
- Per-secret rotation hooks (rotation = `az keyvault secret set` +
  `systemctl restart nemoclaw`).
- A web UI for NemoClaw (whatever NemoClaw natively exposes is fine).
- Monitoring/alerting on unexpected downtime (per Clarifications,
  2026-04-25): the operator detects unplanned outages on next use and
  recovers manually. No Azure Monitor alert rules or Action Groups in
  v1.
