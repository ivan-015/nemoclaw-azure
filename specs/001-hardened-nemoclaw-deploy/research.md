# Phase 0 Research: Hardened NemoClaw Azure Deployment (v1)

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-04-25 (revised same day to reflect spec Q4 / broker
removal — see R4-revised, R6-OBSOLETE, R9-OBSOLETE, R10-revised, R13)

This document resolves every NEEDS CLARIFICATION raised in the spec or
plan, plus the open research items carried over from the operator-facing
`docs/IMPLEMENTATION_PLAN.md`. Each entry follows the schema:

> **Decision** — what was chosen
> **Rationale** — why it was chosen
> **Alternatives considered** — what else was evaluated and why not

> ⚠ **2026-04-25 architectural revision**: spec clarification Q4
> verified that NemoClaw upstream's host-vs-sandbox isolation already
> provides the protection a runtime UDS broker would have added. The
> broker has been removed. R4 now describes the chosen design (not a
> fallback); R6 (broker caching) and R9 (broker IPC) are obsolete; R10
> is revised to describe the simpler audit pipeline (Key Vault
> diagnostic logs); a new R13 covers the KV access mode (service
> endpoint instead of Private Endpoint). Original entries are retained
> below with annotations so the audit trail is intact.

---

## R1. NemoClaw non-interactive install path

**Decision**: At v1, install via the upstream tarball at the pinned
release tag, with NemoClaw's interactive wizard answers pre-supplied
through one of three mechanisms in priority order:

1. **If upstream exposes config-file or environment-variable hooks** that
   bypass the wizard, use them. The implementing engineer MUST search
   the upstream repo (release notes, `--help`, `bin/nemoclaw init
   --help`) before falling back.
2. **If no such hooks exist** as of the implementing date, drive the
   wizard with `expect` consuming a versioned answers file
   (`cloud-init/scripts/nemoclaw-answers.expect`), and *open an upstream
   issue* the same day requesting an unattended-install flag.
3. **Smoke-test path**: cloud-init runs the full install and a basic
   `nemoclaw --version` + `nemoclaw doctor` (or equivalent) check. If
   either fails, cloud-init fails loudly and the apply errors.

**Rationale**: Upstream NemoClaw is six weeks old (released 2026-03-16).
The README does not document an unattended-install path. Waiting for
upstream to add one would block the project; rolling our own answers
file via `expect` is mildly distasteful but bounded — it is encapsulated
in a single versioned file, runs once at first boot, and can be
removed when upstream catches up. Approach #1 is preferred and the
implementer must check first.

**Alternatives considered**:

- **Pre-bake a Packer image** with NemoClaw already installed: defers
  the unattended-install problem to image-bake time but does not solve
  it; also adds a Packer pipeline as a v1 dependency, which the spec
  defers to v2.
- **Skip NemoClaw at v1, deploy only the harness**: makes v1 trivially
  achievable but defeats the project's purpose.
- **Run NemoClaw in a container instead of host install**: NemoClaw's
  sandbox model assumes host-level Landlock + namespaces. Containerising
  the agent runtime would either nest sandboxes (complicated) or
  require giving the container too many capabilities (Principle I
  violation).

---

## R2. NemoClaw's full outbound endpoint list

**Decision**: At v1 the egress NSG allowlist (by service tag where
available, by FQDN service-tag-equivalent otherwise) is:

- `AzureActiveDirectory` (managed identity token issuance)
- `AzureKeyVault.<region>` (KV access via Private Endpoint — note: with
  PE the traffic is private but the service-tag rule keeps the
  fail-closed posture if PE is later removed)
- `Storage.<region>` (state backend access if cloud-init or broker
  needs it)
- `MicrosoftContainerRegistry` + `AzureFrontDoor.FirstParty` (Docker
  Hub upstream + container-registry CDN; needed for Docker layer
  pulls)
- Tailscale: `*.tailscale.com` (HTTPS coordination), `*.relay.tailscale.com`
  (DERP relay), and `UDP/41641` outbound (direct connections). Use
  destination FQDN matching where the NSG allows it; otherwise match
  the Tailscale-published IP ranges with explicit comment.
- `CognitiveServicesManagement.<region>` and the operator-supplied
  Foundry endpoint FQDN (the Foundry endpoint URL is a Terraform input
  variable; render the matching NSG rule with `var.foundry_endpoint`).
- Ubuntu update servers: `archive.ubuntu.com`, `security.ubuntu.com`,
  `azure.archive.ubuntu.com` (the latter is the Azure-mirror,
  preferred for in-region speed).
- NodeSource: `deb.nodesource.com`.

**Rationale**: Service tags are dynamic and Microsoft-maintained, so
they survive Microsoft IP-range changes without operator intervention
— the right shape for a personal project. FQDN-matching for
Tailscale and Ubuntu mirrors gets us narrow rules without manually
tracking IP ranges. This list is intentionally minimal and is
justified destination-by-destination in `docs/THREAT_MODEL.md`.

**Open follow-up**: NemoClaw may call additional telemetry or
sandbox-image-update endpoints not yet documented. The implementer MUST
run the deploy with NSG flow logs enabled, observe deny events for
24 hours under typical usage, and either justify any blocked
destinations or add narrow allow rules. This is captured as a
post-deploy verification step in `quickstart.md`.

**Alternatives considered**:

- **Allow all egress (`Internet` service tag)**: simplest, also
  eviscerates the security posture this project exists to deliver.
  Rejected by Principle I.
- **Require FQDN-only matching for everything (Azure Firewall)**:
  Azure Firewall is ~$900/mo base. Rejected on cost (Principle IV) and
  unnecessary complexity for personal scale.

---

## R3. Tailscale userspace mode vs. kernel mode in NemoClaw's sandbox

**Decision**: Use **kernel-mode Tailscale** at v1 (the default;
`tailscaled` runs as root, opens a `tun0` interface). Document a
fallback to userspace mode in `docs/TAILSCALE.md` should the kernel
mode interact poorly with NemoClaw's network namespaces.

**Rationale**: NemoClaw's sandbox uses Linux network namespaces to
isolate the agent's network access. Kernel-mode Tailscale operates at
the host network namespace level, *outside* the sandbox — so admin
SSH and operator-side service access work. Userspace-mode Tailscale
(`TS_USERSPACE=true`) can traverse namespaces but is markedly slower
and has occasionally surprising behaviour around `iptables` /
`nftables`. Kernel mode is the documented Tailscale default for
servers and is the lower-risk choice.

**Risk**: if NemoClaw expects to use Tailscale *from inside* its
sandbox (it shouldn't — it talks to Foundry directly via its own
network namespace), there could be a conflict. The implementer
verifies this in the smoke test.

**Alternatives considered**:

- **Userspace mode by default**: needlessly slow; surfaces edge cases
  in the absence of evidence we'd hit them.
- **Run Tailscale inside a container alongside NemoClaw**: solves
  nothing; the host still needs a tailnet identity to be admin-
  reachable.

---

## R4. (REVISED) Credential handoff to NemoClaw — systemd `EnvironmentFile=` + tmpfs

**2026-04-25 revised**: this entry was originally a fallback path
("if NemoClaw only supports file-based credentials, do this"). After
reading the upstream `inference-options.html` doc — *"Provider
credentials stay on the host. The sandbox does not receive your API
key"* — this pattern IS the v1 design, not a fallback. The custom
runtime broker has been removed (see spec Q4).

**Decision**:

- A small shell script `04-credential-handoff.sh` runs as
  `ExecStartPre` for the NemoClaw systemd unit.
- It uses `az login --identity` followed by `az keyvault secret show
  --query value -o tsv` to fetch the Foundry API key from Key Vault
  via the VM's user-assigned managed identity.
- It writes a single line `OPENAI_API_KEY=<value>` to `/run/nemoclaw/env`
  on a tmpfs mount, with mode `0400` and ownership `root:nemoclaw`
  (or whatever the NemoClaw host user is).
- The systemd unit has `EnvironmentFile=/run/nemoclaw/env` so the
  service starts with the env var set.
- An `ExecStartPost` directive runs `rm -f /run/nemoclaw/env` (also
  `shred -u` first if paranoid, but tmpfs is RAM-only so unlinking
  is sufficient — there's no disk sector to overwrite).
- NemoClaw's host process holds the env var in process memory; the
  sandboxed agent does not, per NemoClaw's own architecture.

**NemoClaw's persisted-on-disk config audit** (the original R4 topic
at residual scope):

- NemoClaw's persisted config dir (typically `~/.nemoclaw/` or
  `/etc/nemoclaw/` — implementer verifies on first boot) MUST NOT
  contain the Foundry API key. The credential handoff above ensures
  the key never lands on disk.
- Audit during cloud-init smoke test: `grep -rF "$key_value"
  ~/.nemoclaw/ /etc/nemoclaw/` MUST return zero matches before
  cloud-init declares success.

**Rationale**: This pattern is *explicitly named* in constitution
Principle II's permitted-mediation-channel list ("a just-in-time
tmpfs file with restrictive permissions deleted after use"). It is
~30 lines of shell instead of ~600 lines of Go. NemoClaw's own
architecture carries the agent-environ-isolation load.

**Alternatives considered**:

- **Custom UDS broker (the previous R4–R10 architecture)**:
  re-implements protection NemoClaw upstream already provides; ~16
  more tasks; ~600 more lines of Go; not security-equivalent if you
  consider it adds complexity surface.
- **Embed the key directly in NemoClaw's persisted config**: direct
  Principle II violation. Rejected.
- **Set the key as a process env var via shell wrapper before
  invoking NemoClaw**: nearly the same as the chosen design, but
  doesn't use systemd's `EnvironmentFile=` directive — meaning the
  shell wrapper has the key in *its* environ for longer than
  necessary. Less clean.
- **Use `pass` or another userspace credential store**: pulls in a
  GPG dependency just to hold one secret; provides nothing beyond
  what KV + tmpfs already give us.

---

## R4-OLD. (OBSOLETE) NemoClaw's persisted-on-disk configuration fields (Principle II audit)

> ⚠ Superseded by R4 (revised) above. Original text retained below
> for audit trail.

**Decision**: Treat NemoClaw's persisted config directory (typically
`~/.nemoclaw/` or `/etc/nemoclaw/` — verified by the implementer
during the first cloud-init run) as **public-readable from a
threat-model perspective**. The broker MUST NOT write secrets there
under any circumstance. NemoClaw's runtime configuration MUST contain
only:

- The Foundry endpoint URL (non-secret per the spec's Q2 clarification)
- The Foundry deployment name(s) (non-secret)
- The Foundry API version (non-secret)
- The broker UDS path (`/run/nemoclaw-broker.sock`)
- The model/agent policy bundle reference (non-secret)

The Foundry API key, if NemoClaw expects an API-key field at config
time, MUST be sourced via the broker at the moment of need and MUST
NOT be written to NemoClaw's persisted config.

**Rationale**: A future audit of `~/.nemoclaw/` should reveal nothing
that an attacker who reads the file could use to exfil. This is the
operationalisation of FR-009.

**Risk**: NemoClaw may, today, only support API-key configuration via
a config file (not a runtime-fetched value). If so, the implementer
must (a) wrap NemoClaw's invocation with a small shim that fetches
the key from the broker into a tmpfs file with `0400` perms scoped to
NemoClaw's UID, points NemoClaw's config at that file, and unlinks
the tmpfs file after NemoClaw reads it; OR (b) submit a feature
request upstream for runtime credential injection. Option (a) is
acceptable because the file lives in tmpfs (RAM) and is unlinked
*before* NemoClaw enters its sandbox, making it unreachable to
sandboxed processes. This is documented in `docs/BROKER.md` as the
**JIT tmpfs handoff pattern**, allowed by the constitution Principle II
("a just-in-time tmpfs file with restrictive permissions deleted after
use") explicitly.

**Alternatives considered**:

- **Bake the key into NemoClaw's persisted config**: direct Principle
  II violation. Rejected.
- **Set the key as a process env var when spawning NemoClaw**: the
  agent reads its own `/proc/self/environ`. Direct Principle II
  violation. Rejected.

---

## R5. (REVISED) Tailscale auth-key lifecycle and revocation on `terraform destroy`

**2026-04-25 revised** to drop the KV-side purge `null_resource` per
the user's #4 trim — Tailscale's own 24h ephemeral expiry is the
v1 mitigation.

**Decision**: At v1, the Tailscale auth key is **manually managed** by
the operator:

- The operator generates a *reusable: false, ephemeral: true,
  pre-approved: true, expiry: 24h* key in the Tailscale admin console
  before the first apply.
- The operator places the key into Key Vault under a
  Terraform-stable secret name (e.g., `tailscale-auth-key`).
- Cloud-init fetches it once via the VM's managed identity, registers
  the node with `tailscale up`, scrubs the key from cloud-init logs
  in-memory.
- The KV-side secret persists post-boot. **Mitigation**: Tailscale's
  own 24h ephemeral expiry makes the persisted KV value useless 24
  hours after generation. v2 may add a `null_resource` purge for
  belt-and-suspenders.
- On `terraform destroy`, the operator MUST manually revoke the
  *node* in the Tailscale admin console (Tailscale auth keys
  auto-revoke their *issuance*, but the node itself stays registered
  until removed). v1 documents this as a manual destroy-time step;
  v2 adds a `null_resource` provisioner that hits the Tailscale API
  to revoke the node.

**Rationale**: The Tailscale REST API requires a separate Tailscale
API token (different from the auth key), which itself would need to
live somewhere. Manual revocation of *one* node, *once* per destroy,
plus reliance on the 24h auth-key expiry, is acceptable for a
personal deploy. Removing the `null_resource` cuts a flaky
`local-exec` dependency on the operator's `az login` being authenticated
at apply time.

**Alternatives considered**:

- **Use a non-ephemeral auth key**: violates spec FR-012 ("one-time
  use"). Rejected.
- **Keep the KV-side purge `null_resource`**: belt-and-suspenders
  with a flaky `local-exec` dependency. v2 candidate.
- **Embed a Tailscale API token in tfvars for automated revoke**:
  introduces a new long-lived credential to manage. v2 candidate.

---

## R6. (OBSOLETE) Broker caching algorithm

> ⚠ **Obsolete as of 2026-04-25** — the runtime broker has been
> removed (spec Q4). There is no cache to algorithm-pick. The
> credential handoff fetches from KV once per NemoClaw service start
> (typically once per day, given auto-shutdown). Original entry
> retained below for audit trail.

**Decision**: **Per-caller-PID cache, evicted on PID exit**, with a
hard TTL ceiling of 5 minutes to bound staleness from key rotation.

Concretely:

- Cache key: `(secret_name, caller_pid)`.
- Cache value: the secret bytes + the fetch timestamp.
- A goroutine watches `/proc/<pid>` (or uses `pidfd_open` on Linux ≥
  5.3) and evicts the entry when the PID dies.
- A second goroutine evicts any entry older than 5 minutes regardless
  of PID liveness.
- Cache miss = full KV round trip + audit-log emit.
- Cache hit = audit-log emit at lower verbosity ("served-from-cache:
  yes") so the audit trail still shows every consumption, just not
  every KV read.

**Rationale**: This algorithm matches the threat model tightest. A
fetch is bounded both by *who is fetching* (peer-cred auth) and *how
long the fetcher has been alive*. When NemoClaw restarts, its cache
is gone — exactly the security posture we want. The 5-minute hard
TTL ensures rotation propagates without operator action even in
long-lived process scenarios.

**Alternatives considered** (per the Q3 mini-survey):

- **Time-based TTL only**: simpler but doesn't tie cache lifetime to
  the trust boundary (the calling process). A 30-second TTL would
  serve secrets to a spawned child process the same way as to the
  legitimate caller, defeating the per-caller specificity that
  peer-cred auth gives us.
- **KV-version-metadata refresh**: best for rotation freshness, but
  requires an extra Azure call per request and adds a second
  KV-permissions consideration (`secrets/listversions`). Not worth
  it at single-operator scale.
- **Stale-while-revalidate**: solves a problem we don't have (KV
  flakiness with PE is rare). Adds complexity.
- **No cache (strict on-demand)**: highest audit fidelity but
  unnecessary KV load for repeated calls within a single inference
  session.

---

## R7. Re-deploy uniqueness mechanism (FR-026)

**Decision**: A 4-character random suffix appended to all
**globally-unique-name resources** (Key Vault, Storage), seeded by
`random_string` at first apply and stored in remote state. The suffix
remains stable across applies on the same state, so `terraform apply`
is idempotent. To force a fresh suffix (e.g., after a destroy that
soft-deleted the Key Vault), the operator runs `terraform taint
random_string.deploy_suffix && terraform apply`.

**Rationale**: Soft-deleted Key Vaults retain their name globally for
the soft-delete retention window (90 days default). Without a unique
suffix, redeploying after a destroy would fail to re-create the KV.
A random suffix is the simplest mechanism that doesn't require the
operator to manually choose a new name each time.

**Alternatives considered**:

- **Date-based suffix (e.g., `-20260425`)**: human-readable but
  unstable (changes every day, would tear down and re-up the KV on
  every apply). Rejected.
- **Operator-supplied suffix as required tfvar**: pushes the
  uniqueness problem onto the operator. Annoying for a personal
  project. Rejected.
- **Disable purge protection**: lets us skip the suffix dance, but
  Principle I + constitution Security Constraints require purge
  protection ON. Rejected.

---

## R8. NemoClaw upstream stability and version-pin ergonomics

**Decision**: NemoClaw release tag is a single Terraform variable
`var.nemoclaw_version`, with no default — the operator must
explicitly choose a version on first apply. The variable is read by
cloud-init via the rendered template. A version change requires
`terraform apply` and triggers a VM replacement (via
`triggers = { nemoclaw_version = var.nemoclaw_version }` on a
`null_resource` that the VM depends on, or via the cloud-init
template's hash change cascading to VM `custom_data` change).

**Rationale**: NemoClaw is six weeks old; the version-pin is the
primary lever an operator has when upstream ships a regression. Making
it explicit (no default) prevents silent upgrades; making it a
`terraform apply` operation makes upgrades reviewable as a diff. VM
replacement is the right behaviour: a partial in-place upgrade of
NemoClaw on the same VM would leave residue from the previous version
on the persistent disk, undermining reproducibility (Principle V).

**Alternatives considered**:

- **In-place upgrade via cloud-init re-run**: cloud-init by design
  runs once per instance; coercing it to re-run is fragile.
- **Default the version to "latest"**: trivial-to-write supply-chain
  attack. Rejected by Principle V.
- **Pin in code (not tfvars)**: makes upgrades require a code change
  rather than a config change, which is slightly *more* friction —
  but also more visible in `git log`. Rejected only because tfvars
  + diff review preserves visibility while reducing the friction
  level appropriately for a personal project.

---

## R9. (OBSOLETE) Broker IPC framing

> ⚠ **Obsolete as of 2026-04-25** — no broker, no IPC. Original
> entry retained below for audit trail.

**Decision**: Length-prefixed JSON over UDS. Each message is a
4-byte big-endian length followed by `length` bytes of UTF-8 JSON.
The protocol is request/response, single-shot per connection — the
client opens a connection, sends one request, reads one response,
closes. No multiplexing, no streaming.

**Rationale**: JSON is debuggable with `nc -U` + a hex dump. Length
prefixing avoids ambiguity. Single-shot connections eliminate any
state-machine concerns. Go's `encoding/json` and `net.UnixListener`
make the implementation < 200 lines.

**Alternatives considered**:

- **HTTP over UDS** (Go's `net.UnixListener` + `http.Server`): more
  ceremony for no benefit at single-operator scale.
- **gRPC over UDS**: protobuf compilation step, dependency on a
  client lib in NemoClaw's process — adds dependencies for no benefit.
- **A custom binary protocol**: fewer bytes, harder to debug, no
  perceptible upside.

---

## R10. (REVISED) Audit pipeline — Key Vault diagnostic logs

**2026-04-25 revised**: with the broker removed (spec Q4), audit comes
from Key Vault's own diagnostic logs, not a custom journald emitter.

**Decision**: Key Vault diagnostic settings stream `AuditEvent` and
`AllMetrics` categories to the Log Analytics workspace. Every
`SecretGet` operation by the VM's managed identity is recorded
automatically by Azure with timestamp, identity, requestUri, and
result code. SC-008 ("100% audit landing within 5 min") is met by
Azure's standard diagnostic-log dispatch latency.

KQL example for the v1 audit query:

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| where identity_claim_oid_g == "<vm-mi-principal-id>"
| project TimeGenerated, requestUri_s, ResultSignature, ResultDescription
```

**Rationale**: Azure's audit is the right level for "secret was
accessed" — it captures the access at the source. A custom emitter
on the VM would have captured the *same* event one hop later,
duplicating Azure's work and adding code surface for no information
gain. With one consumer (the credential handoff script), audit
volume is trivial — one record per NemoClaw service start.

**Alternatives considered**:

- **Custom journald emitter from the credential handoff script**:
  Azure already records the KV access; this would just duplicate.
  Skipped.
- **Include cloud-init logs (Tailscale auth-key fetch) in the audit
  pipeline**: cloud-init logs are in `/var/log/cloud-init.log` on the
  VM and are visible via `az vm boot-diagnostics get-boot-log` for
  emergency forensics. Not centrally indexed at v1; v2 candidate via
  AMA + a Linux Syslog DCR. The KV diagnostic log already records
  the Tailscale auth-key fetch from the same managed identity, so the
  audit *of the secret access itself* is intact.

---

## R10-OLD. (OBSOLETE) Broker → Log Analytics audit pipeline

> ⚠ Superseded by R10 (revised) above.

---

## R11. State backend bootstrap recovery

**Decision**: `terraform/bootstrap/` is run **once** with local state.
The local state file is gitignored. Recovery path: re-run
`terraform init` against the existing storage account (from
operator-recorded outputs) and run
`terraform import azurerm_storage_account.state ...` to repopulate
local state if lost; or simply `terraform refresh -refresh-only`
against the existing remote resources.

**Rationale**: The bootstrap is the smallest possible surface (RG,
storage, container) and is created once per subscription. Losing the
local state file is annoying but not catastrophic — the resources are
discoverable in the Azure portal and re-importable.

**Alternatives considered**:

- **Skip bootstrap; use a pre-existing storage account** the operator
  creates manually: violates Principle V (deploy MUST NOT depend on
  portal clicks). Rejected.
- **Bootstrap stage uses GitHub Actions OIDC + workflow-issued state
  account**: out of scope; this is a personal-laptop deploy.

---

## R12. Operator workstation prerequisites

**Decision**: The README enumerates and checks for:

- `az` CLI authenticated to the personal subscription
- `terraform >= 1.6`
- `gh` (only needed if cloning from GitHub; not strictly required if
  the operator already has the source)
- Tailscale client installed and authenticated
- A `quickstart.sh` (optional, v2) that verifies all of the above and
  refuses to proceed if any is missing

**Rationale**: A personal-project README that says "you also need X,
Y, Z" but doesn't fail-fast when they're missing is the worst kind
of documentation. Either the README is short enough that the operator
reads every line (v1 target), or it ships with a check script
(v2 target).

**Alternatives considered**:

- **Containerise the toolchain**: introduces Docker as a dependency
  for the operator workstation, which on macOS means Docker Desktop
  ($$) or Colima (works fine but is yet another tool).
- **Devcontainer / Codespaces**: same problem inverted; ties the
  operator to a specific IDE.

---

## R13. (NEW) Key Vault network access mode — service endpoint vs. Private Endpoint

**2026-04-25 new** (per the user's #1 trim approval).

**Decision**: Use a VNet **service endpoint** (`Microsoft.KeyVault`)
on the `vm` subnet, plus a Key Vault `network_acls` block restricting
allowed access to that single subnet (`bypass = "AzureServices"`,
`default_action = "Deny"`, `virtual_network_subnet_ids = [vm_subnet_id]`).

**Rationale**: Functionally equivalent to a Private Endpoint for our
single-VM single-consumer scenario:

- KV is unreachable from the public internet (`public_network_access_enabled = false`).
- Only the deployment's `vm` subnet can reach KV.
- All traffic traverses the Azure backbone, not the internet.

But cheaper (zero marginal cost vs. ~$7/mo per Private Endpoint) and
simpler (no Private DNS Zone, no `azurerm_private_dns_zone`,
`azurerm_private_dns_zone_virtual_network_link`,
`azurerm_private_endpoint`, `azurerm_private_dns_a_record` resources
to manage). Constitution Security Constraints permits "Private
Endpoint when network design allows" — at single-VM scale, the
service-endpoint design satisfies the underlying intent (KV not on
the internet) without the ceremony.

**v2 upgrade trigger**: when this deployment grows to multiple
consumers (e.g., a second VM, a Container Apps environment,
cross-subscription access), Private Endpoint becomes the right
tool because it gives KV a stable private IP routable from anywhere
peered into the VNet. Until then, service endpoint suffices.

**Alternatives considered**:

- **Private Endpoint**: ~$7/mo, more resources, more DNS state. Right
  for multi-VNet scenarios; overkill here.
- **No network restriction (just RBAC)**: relies entirely on Azure AD
  for access control. Constitution requires
  `public_network_access_enabled = false` regardless. Rejected.

---

## Resolved NEEDS CLARIFICATION roll-up

| Source | Item | Resolved by |
|---|---|---|
| spec.md Open Q1 (deferred from /speckit-clarify) | NemoClaw unattended install | R1 |
| docs/IMPLEMENTATION_PLAN.md Open Q1 | NemoClaw unattended install | R1 |
| docs/IMPLEMENTATION_PLAN.md Open Q2 | Outbound endpoint list | R2 |
| docs/IMPLEMENTATION_PLAN.md Open Q3 | Sandbox/UDS interaction | R3 + R4 |
| docs/IMPLEMENTATION_PLAN.md Open Q4 | Persisted-on-disk config audit | R4 |
| docs/IMPLEMENTATION_PLAN.md Open Q5 | Tailscale userspace vs kernel | R3 |
| docs/IMPLEMENTATION_PLAN.md Open Q6 | Tailscale auth-key lifecycle | R5 |
| spec.md Q3 | Broker caching policy → algorithm | R6 (now obsolete — see Q4) |
| spec.md Q4 | Broker vs. simpler EnvironmentFile pattern | R4 (revised) |
| User trim #1 | KV network access mode | R13 (new) |
| User trim #4 | Tailscale KV-side purge | R5 (revised) |
| spec.md FR-026 | Re-deploy uniqueness mechanism | R7 |
| docs/IMPLEMENTATION_PLAN.md Open Q7+Q8 | NemoClaw upstream stability + version-pin | R8 |
| Implicit (broker IPC schema) | Wire protocol | R9 |
| Implicit (audit log path) | Journald → AMA → LA | R10 |
| Implicit (bootstrap recovery) | Local state recovery | R11 |
| Implicit (operator prereqs) | Toolchain doc | R12 |

No remaining `NEEDS CLARIFICATION` markers carry into Phase 1.
