<!--
SYNC IMPACT REPORT
==================
Version change: none → 1.0.0 (initial ratification)

Modified principles: N/A (initial creation)

Added sections:
  - Core Principles (I–V)
  - Security Constraints
  - Cost & Operational Constraints
  - Governance

Removed sections: none

Templates requiring updates:
  - .specify/templates/plan-template.md       ✅ no edit needed (Constitution
    Check section already references the constitution by abstraction:
    "[Gates determined based on constitution file]")
  - .specify/templates/spec-template.md       ✅ no edit needed (no
    principle-specific scaffolding required at this version)
  - .specify/templates/tasks-template.md      ✅ no edit needed (phases are
    generic and constitution-agnostic)
  - .specify/templates/commands/*             ✅ no agent-specific references
    requiring genericisation
  - README.md                                  ⚠ pending (project README does
    not yet exist; first PR adding it must reference this constitution)
  - docs/THREAT_MODEL.md                       ⚠ pending (mandated by
    Section: Security Constraints; create when network/identity surface
    materialises in code)

Follow-up TODOs: none — all placeholders concretely defined at v1.0.0.
-->

# nemoclaw-azure Constitution

## Core Principles

### I. Security as Default, Not Add-On

Defense in depth across network, identity, runtime, and secrets is a baseline,
not a finishing touch. Network Security Groups MUST default-deny ingress and
list only explicitly justified rules. Public SSH MUST be disabled; host access
MUST be brokered through Azure Bastion or equivalent, or omitted entirely.
Managed identities MUST be used in place of service principals wherever Azure
supports them. The upstream NemoClaw sandbox hardening — Landlock, seccomp, and
network namespaces — MUST be preserved as NemoClaw ships it; this repository
MUST NOT relax it for convenience. Disk encryption MUST be enabled (Azure
platform-managed key acceptable for v1).

**Rationale**: NemoClaw's value proposition is hardened agent execution. A
deploy that loosens the host's posture nullifies the project; the deploy MUST
be at least as defensible as a stock NemoClaw install on a developer
workstation.

### II. Secrets Never Touch the Agent's Environment (NON-NEGOTIABLE)

NemoClaw, and any process spawned within its sandbox, MUST NOT receive secrets
(API keys, tokens, connection strings, certificates) via process environment
variables, baked-in configuration files, command-line arguments, or files
written to a path the agent can read at provision time. Secrets MUST be
fetched on-demand from Azure Key Vault using the host's managed identity,
scoped to the specific operation requiring them, with the shortest viable TTL,
and surfaced to NemoClaw only through a mediated channel (e.g. a local broker
on a Unix domain socket; a just-in-time tmpfs file with restrictive
permissions deleted after use). Long-lived secrets MUST NOT be materialised
into the agent's reachable filesystem at all.

**Rationale**: an LLM-driven agent that can read its own `/proc/self/environ`
is one prompt injection away from exfiltrating every credential the host
holds. This is the precise threat NemoClaw exists to mitigate, and the deploy
MUST NOT undermine it. This principle is the project's reason for existing —
violations are not acceptable, even temporarily, even behind a flag.

### III. Least Privilege Everywhere

The host's managed identity MUST be granted the narrowest RBAC scope that
permits the deploy to function: prefer built-in scoped roles, define a custom
role when no built-in is narrow enough, and forbid `Owner` and `Contributor`
at any scope. NSG rules MUST NOT use `*` for source or destination; any
deviation requires an in-rule comment justifying the breadth. Storage accounts
MUST set `public_network_access_enabled = false` where Private Endpoint or
service endpoint coverage exists. Key Vault MUST use RBAC authorization (not
access policies) and MUST disable public network access in the default
configuration.

**Rationale**: blast-radius limitation. When (not if) something is
compromised, what the compromised principal can reach matters more than
whether the compromise occurred. This principle is enforceable in code review
by reading the Terraform diff alone.

### IV. Cost-Conscious by Default

The default VM SKU MUST be sized to NemoClaw's stated 4 vCPU / 16 GB RAM
recommendation: target `Standard_B4ms` (burstable, 4 vCPU, 16 GB) as the
default profile. `Standard_B2ms` (2 vCPU, 8 GB) is acceptable for low-duty
personal use given NemoClaw's documented 8 GB minimum with swap. An
auto-shutdown schedule (`azurerm_dev_test_global_vm_shutdown_schedule`) MUST
be exposed as an opt-in input. Services with hourly minimums (Application
Gateway, NAT Gateway, Premium Storage tiers, Dedicated Hosts) MUST NOT appear
in the default profile and require an explicit cost note when added. The
default Azure region SHOULD be a low-cost stable region (e.g., `eastus2` or
`northeurope`), user-overridable.

**Rationale**: a security-focused personal deploy that costs USD 400/month
will sit unused — and unused security tooling is the worst kind. Affordability
is itself a security feature because it makes the difference between "I'd
deploy this" and "I'd think about deploying this."

### V. Reproducible & Auditable Deployments

All Azure infrastructure MUST be expressed as Terraform using the `azurerm`
provider; the deploy MUST NOT depend on portal clicks, ad-hoc CLI commands, or
out-of-band scripts for resources within its scope. Provider versions MUST be
pinned in `required_providers` (`~>` for minor flexibility on routine
providers; exact pin for security-critical providers). Terraform state MUST
live in a remote backend (Azure Storage), with state locking enabled and
server-side encryption on. The chicken-and-egg of bootstrapping that backend
itself MUST be documented (a separate `terraform/bootstrap/` module run once
with local state, then migrated to the remote backend). Variables affecting
security posture MUST use `validation` blocks where invalid input would
produce an insecure result (e.g., reject `0.0.0.0/0` in any allowed-IP
input). Composition MUST be via modules; copy-paste between root modules is
prohibited. `terraform fmt` and `terraform validate` MUST pass before merge.
Secrets MUST NOT appear in `.tfvars` committed to git — use Key Vault data
sources at apply time, or `*.tfvars.example` with placeholders. The NemoClaw
install MUST be invoked from a pinned upstream release tag (never `main`); the
version MUST be a Terraform input variable so upgrades are explicit, reviewed,
and revertible.

Terragrunt is intentionally NOT adopted in v1: the DRY-across-environments
value it offers does not justify its complexity tax for single-environment
personal infrastructure. This decision MUST be revisited if a second
environment is introduced.

**Rationale**: an auditable deploy is one a stranger can clone, read, and
reason about within an hour. Reproducibility means the next NemoClaw upgrade
is a deliberate change with a diff, not a debugging session.

## Security Constraints

The following are concrete, code-reviewable rules implementing the principles
above. Violations MUST be flagged in the PR opening notes with explicit
justification and a rollback plan.

- **NSG rules**: no `*` source on ingress; SSH (TCP/22) closed by default;
  Bastion-only access pattern when host shell access is required.
- **Storage accounts**: `public_network_access_enabled = false`,
  `min_tls_version = "TLS1_2"`, `allow_nested_items_to_be_public = false`,
  `shared_access_key_enabled = false` where Azure AD auth is feasible.
- **Key Vault**: RBAC mode; `public_network_access_enabled = false` paired
  with Private Endpoint when network design allows; soft-delete and purge
  protection ON; diagnostic logs streamed to Log Analytics.
- **Diagnostic logs**: NSG flow logs, VM boot diagnostics, and Key Vault audit
  events MUST flow to a Log Analytics workspace with retention ≥ 30 days.
- **Disk encryption**: platform-managed key acceptable for v1; the upgrade
  path to a customer-managed key MUST be documented in `docs/THREAT_MODEL.md`.
- **Threat model**: `docs/THREAT_MODEL.md` MUST exist (created with the first
  PR that introduces network or identity resources) and MUST be updated
  whenever a PR changes the network surface, identity model, or
  secret-handling path.
- **No hardcoded sensitive values**: CIDR ranges, subscription IDs, principal
  IDs, tenant IDs, region names, and any user-specific identifier MUST be
  surfaced as Terraform variables, never literal in module bodies.

## Cost & Operational Constraints

- **Tags**: every Azure resource MUST carry the tags `project =
  "nemoclaw-azure"`, `owner` (an email or GitHub handle), `cost-center`
  (free-form, default `personal`), and `managed-by = "terraform"`.
- **Default VM SKU**: on-demand list price MUST be ≤ USD 130/month (covers
  `Standard_B4ms`); cheaper SKUs are preferred when NemoClaw runs cleanly on
  them.
- **Hourly-minimum services**: opt-in only. Any PR introducing such a resource
  MUST include a one-line cost note in the PR description.
- **Default region**: `eastus2` unless overridden by the user; the README MUST
  document the latency-vs-price trade-off briefly.
- **Auto-shutdown**: an opt-in auto-shutdown schedule SHOULD be enabled by
  default in personal-use example tfvars (e.g. `examples/personal.tfvars`).

## Governance

This constitution supersedes ad-hoc decisions made in code, comments, or chat.
If a pull request conflicts with a principle, either the PR is changed to
comply or the constitution is amended in the same PR (never silently).

This is a single-maintainer project; governance is adapted accordingly:

- **All changes via PR**, including self-PRs. Self-review is permitted for
  non-security-affecting changes.
- **24-hour cool-off for security-affecting changes**: any PR that touches
  network rules, identity / RBAC bindings, secret-handling code paths,
  sandbox / runtime configuration, or Key Vault access MUST sit open for a
  minimum of 24 hours between opening and self-merge. Rationale: errors of
  this kind are caught with fresh eyes, not the eyes that wrote them.
- **Non-default Azure resources**: any PR adding a resource not in the
  baseline (VM, VNet, Subnet, NSG, Key Vault, Log Analytics workspace, plus
  managed identity bindings) MUST include a PR-note justifying both the cost
  delta (USD/month, on-demand) and the security delta (what surface it adds
  or reduces).
- **NemoClaw upstream version bumps**: changing the pinned NemoClaw release
  tag MUST be validated in a throwaway resource group before merging the
  variable change. The PR description MUST record the test (region used, SKU
  used, install completion confirmed, basic health check confirmed). Cleanup
  of the throwaway RG MUST be confirmed in the same description.
- **External contributors**: this is an open-source personal project;
  external PRs are welcome but the maintainer retains final decision authority
  on all merges. Contributors are bound by this constitution.
- **Constitution amendments** follow semantic versioning:
  - **PATCH**: clarifications, wording, typo fixes, non-semantic refinements.
  - **MINOR**: a new principle or section added, or materially expanded
    guidance within an existing principle.
  - **MAJOR**: backward-incompatible governance change, principle removal, or
    principle redefinition (e.g., relaxing Principle II in any way would be
    MAJOR).
- **Compliance review**: every PR description MUST include a one-line note
  affirming "Constitution principles I–V reviewed; no violations" or listing
  specific violations with justification. The cool-off clock starts when this
  affirmation is present, not when the PR opens.

**Version**: 1.0.0 | **Ratified**: 2026-04-25 | **Last Amended**: 2026-04-25
