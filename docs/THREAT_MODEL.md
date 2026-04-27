# Threat Model: Hardened NemoClaw Azure Deployment (v1)

**Status**: Initial — covers v1 scope.
**Constitution**: [v1.0.0](../.specify/memory/constitution.md) (Security Constraints mandates the existence and upkeep of this file.)
**Spec**: [specs/001-hardened-nemoclaw-deploy/spec.md](../specs/001-hardened-nemoclaw-deploy/spec.md)
**Plan**: [specs/001-hardened-nemoclaw-deploy/plan.md](../specs/001-hardened-nemoclaw-deploy/plan.md)
**Research**: [specs/001-hardened-nemoclaw-deploy/research.md](../specs/001-hardened-nemoclaw-deploy/research.md) (R4 revised, R10 revised, R13 new)

This document is a *living* model. Per constitution Security Constraints
it MUST be updated whenever a PR changes the network surface, the
identity model, or any secret-handling path.

---

## Assets

| Asset | Why it matters | Where it lives |
|---|---|---|
| **NemoClaw host process** | Runs the inference gateway; holds the Foundry API key in process memory for its lifetime | systemd service on the VM; user `nemoclaw` |
| **Sandboxed agent** | The LLM-driven process that interprets prompts; the precise threat surface Principle II protects | Spawned by NemoClaw inside Landlock + seccomp + network-namespace sandbox |
| **Foundry API key** | Allows arbitrary inference billed to operator's Foundry instance; can be exfiltrated and re-used | Key Vault secret `foundry-api-key`; transits a tmpfs file at service startup |
| **Tailscale auth key** | One-time bootstrap credential used to register the VM on the operator's tailnet | Key Vault secret `tailscale-auth-key`; consumed once by cloud-init |
| **VM disk** | Holds NemoClaw binaries, agent persistent state, OS logs | Azure managed disk, platform-managed encryption |
| **Key Vault** | Source of truth for the two true secrets | Azure Key Vault, RBAC mode, public access disabled |
| **Terraform state** | Records every resource and its sensitive attributes (KV URI, MI principal IDs) | Azure Storage backend (`bootstrap/` stage); public access disabled, shared keys disabled |
| **Operator's tailnet identity** | The only path into the VM | Tailscale account, out of scope for this repo's controls |

---

## Attackers

| Attacker | Capability assumption | Goal |
|---|---|---|
| **Prompt-injected agent** | Can fully control the sandboxed agent's behaviour via untrusted input | Read its own environment, command line, on-disk config, or `/proc/self/*` to exfiltrate the Foundry API key or any other long-lived credential |
| **Lateral mover (host-level)** | Has somehow gained code execution as a non-root user on the VM (e.g., a sandbox escape, an unpatched service vuln) | Pivot to the host's managed identity, list Key Vault secrets, exfiltrate |
| **Lost / stolen laptop** | Possesses the operator's workstation, may or may not have unlocked it | Use stored Azure CLI tokens, Tailscale node credentials, or Terraform state-backend keys to reach the deployment |
| **Compromised CI / supply chain** | Controls a build artifact the deploy depends on (NemoClaw release tarball, Tailscale package, Docker layer, NodeSource repo, Ubuntu mirror) | Land malicious code on the VM at first boot |
| **Public-internet scanner** | Random opportunist scanning Azure IP space | Find a reachable port, exploit it |
| **Azure tenant cohabitant** | Another principal in the same Azure tenant with broad read | Discover and read Key Vault secrets cross-subscription |

This list is intentionally not exhaustive. It captures the attackers
the v1 design *takes a position on*. Attackers not enumerated here
(e.g., nation-state with kernel zero-day on the Azure host) are
explicitly out of scope for v1 and out of scope for the constitution.

---

## Mitigations

### Principal mitigation: NemoClaw upstream's host-vs-sandbox credential isolation

NemoClaw's own architecture (per upstream `inference-options.html`:
*"Provider credentials stay on the host. The sandbox does not receive
your API key"*) intercepts inference-provider credentials at the host
process and never propagates them into the sandboxed agent's
environment, command line, or filesystem view. **This is the
load-bearing mitigation for the prompt-injection exfiltration threat
(spec FR-009 / SC-004).** This deploy's job is to make sure the
host-side credential never came from a filesystem-stored or
tfvars-stored value.

### Mediation channel: OpenShell intercepts inference traffic on the host

Upstream NemoClaw's architecture provides the load-bearing mitigation
that satisfies Principle II — host-vs-sandbox credential isolation
implemented at the network-namespace boundary:

- The OpenClaw agent runs inside an OpenShell-managed sandbox (Docker
  container with Landlock + seccomp + a private network namespace).
- Inside that namespace, the agent's only route to inference is a
  hostname `inference.local` that resolves *only* on the OpenShell
  gateway proxy. The sandbox cannot reach the actual provider
  (Foundry, OpenAI, etc.) directly.
- The OpenShell gateway runs on the host with the provider API key
  loaded from `~/.nemoclaw/credentials.json` (chmod 0600, owned by
  the operator user). It proxies the agent's inference calls,
  injecting the credential at egress and passing the response back.
- Per upstream's `inference-options.md`: *"Provider credentials stay
  on the host. The sandbox does not receive your API key."*

The Foundry API key reaches the OpenShell gateway at install time
via this deploy's cloud-init flow:

1. Cloud-init runs `05-nemoclaw.sh` as root with the VM's managed
   identity. It fetches `foundry-api-key` from Key Vault using
   `az keyvault secret show`.
2. The key is piped (via stdin only — never on argv, never in env
   that survives the script) into a runner script that invokes
   upstream's `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`
   with `NEMOCLAW_PROVIDER=custom`, `COMPATIBLE_API_KEY=<the key>`,
   `NEMOCLAW_ENDPOINT_URL=<foundry /openai/v1 base>`, and the
   non-interactive flags.
3. The installer + `nemoclaw onboard` validate the credential
   against Foundry, then persist it under
   `~/.nemoclaw/credentials.json` (mode 0600). The runner script's
   stdin closes; the cloud-init script `unset`s and exits.
4. Once OpenShell + the sandbox are running, the operator runs
   `nemoclaw <sandbox> connect` over Tailscale SSH. They enter the
   sandbox shell. From inside, inference calls go to `inference.local`
   → OpenShell gateway → Foundry. The agent's environ, cmdline, and
   filesystem view never contain the key.

Steady-state secret residency:
- On disk in `~/.nemoclaw/credentials.json` (operator-only readable).
  This is upstream's expected pattern — the file is the durable
  source of truth for OpenShell, used on every gateway restart.
- In OpenShell gateway process memory while running.
- **Not** in the sandbox container's environ, cmdline, or filesystem
  view. The Landlock policy explicitly excludes the operator's home
  directory from the sandbox's read paths.

### Network: Tailscale-only ingress, default-deny NSG

- VM has no public IP (FR-001).
- NSG has zero inbound allow rules (FR-002).
- Tailscale is the only admin/service path (FR-003).
- Outbound is allowlisted to a stated set of service tags + FQDNs
  (FR-004; research R2). Other outbound is denied by NSG.
- No SSH-key infrastructure provisioned; no Bastion (FR-005).
- Azure Run Command + serial console remain available as
  control-plane debug paths independent of any inbound rule (FR-006).

### Key Vault: VNet service endpoint + network ACL

- `public_network_access_enabled = false`.
- `network_acls { default_action = "Deny", virtual_network_subnet_ids = [vm_subnet] }`.
- `Microsoft.KeyVault` service endpoint enabled on the VM subnet.
- RBAC mode (no access policies); soft-delete ON; purge protection ON.
- Diagnostic settings stream `AuditEvent` + `AllMetrics` to Log
  Analytics — every `SecretGet` recorded by Azure (FR-010 / SC-008).
- Functionally equivalent to a Private Endpoint at our single-VM
  scale and zero marginal cost (research R13).

### Identity: managed identity, narrowest viable RBAC

- The VM uses a *user-assigned* managed identity (separable from the
  VM lifecycle if needed).
- The identity is granted `Key Vault Secrets User` at the **Key Vault
  resource scope** — not subscription, not RG, not "Owner".
- No service principal, no client secret, no certificate.

### Secret hygiene at the source

- Foundry API key and Tailscale auth key are placed in Key Vault by
  the operator out of band (`az keyvault secret set`); never appear
  in Terraform variable values or `.tfvars` files (constitution
  Principle V).
- Cloud-init scrubs the Tailscale auth key from its in-memory log
  lines after use (FR-012). The persisted KV-side value becomes
  useless after Tailscale's 24h ephemeral expiry (research R5
  revised); v2 may add a `null_resource` purge for
  belt-and-suspenders.
- Terraform state is in an Azure Storage backend with
  `public_network_access_enabled = false` and
  `shared_access_key_enabled = false`; access is via Azure AD only.

### Reproducibility and pinning (Principle V)

- `azurerm` provider exact-pinned at `4.70.0`.
- Ubuntu image SKU pinned in Terraform.
- NemoClaw release tag is a required Terraform variable; no default,
  rejecting `main` / `latest` / `head` at validation time.
- NemoClaw tarball is fetched from the GitHub release URL with a
  `.sha256` checksum verification before extraction (T026).
- Docker CE pinned to a specific version via cloud-init template var.

---

## Residual risks (accepted at v1)

| Risk | Why accepted at v1 | Upgrade path |
|---|---|---|
| **NemoClaw zero-day in the sandbox layer** | The whole project leans on NemoClaw's sandbox holding. A zero-day in Landlock/seccomp/namespace handling defeats Principle II's load-bearing mitigation. | Maintain pinned-version discipline + NemoClaw upstream advisory monitoring. v2: subscribe to NemoClaw security mailing list; CVE alerts. |
| **OpenShell gateway holds the provider API key in `~/.nemoclaw/credentials.json` and in its process memory for the lifetime of the gateway** | This is upstream's design — credential persistence on the host is what enables the sandbox-isolation guarantee. The credentials file is mode `0600` owned by the operator user; the sandbox container's filesystem-policy explicitly excludes the operator's home directory. | Out of v1 scope to mitigate further; would require NemoClaw upstream changes (e.g. fetching the credential from a sidecar at every inference call). |
| **Foundry API key briefly transits the cloud-init script's stdin pipe at install time** | The key is fetched from KV via the VM's managed identity, piped into the upstream installer's runner script via stdin (never argv, never persistent env), and `unset` after. The window is the duration of `nemoclaw onboard`'s provider-validation + sandbox-creation steps (~30–60s). | Acceptable at v1. v2 candidate: a wrapper command that fetches the credential per-session from KV instead of persisting it locally. |
| **Persisted KV-side Tailscale auth key for ≤ 24h** | Tailscale's own 24h ephemeral expiry makes the persisted value useless after the window; explicit purge would require a flaky `local-exec` `null_resource`. | v2: `null_resource` running `az keyvault secret delete` on the auth key after `tailscale up` reports success in cloud-init. |
| **Manual Tailscale node revocation on `terraform destroy`** | Automated revocation requires a Tailscale API token, which itself becomes a long-lived credential to manage. | v2: introduce a Tailscale API key in Key Vault and a `null_resource` provisioner that revokes the node on destroy. |
| **Tailscale account / coordination plane compromise** | The operator's tailnet is the sole ingress path; if Tailscale itself is breached, the threat model changes. | Out of repo scope. Operator should enable Tailscale 2FA, use SSO with their primary identity provider, and review tailnet ACLs periodically. |
| **Lost laptop with unlocked Azure CLI session** | The laptop is the only machine that can `terraform apply` and the only one with a tailnet identity. | Operator should keep the workstation OS-locked, Azure CLI sessions short-lived, and revoke the laptop's Tailscale node if lost. |
| **Compromised NemoClaw upstream release** | Pinned-version + SHA-256 checksum verification reduces the window, but a release signed by a compromised maintainer would still install. | v2: verify the release's GitHub Actions provenance attestation (SLSA L3) before extraction. |
| **Compromised Ubuntu / Docker / NodeSource mirror** | We trust the upstream package signing keys. A stolen signing key would still let a malicious package land. | Out of v1 scope; same trust assumption as every Linux deploy on Earth. |
| **NemoClaw expanding its outbound endpoint set without notice** | The egress NSG allowlist is narrow; an upstream version that adds a new endpoint would be silently denied at the NSG layer (failure mode visible in flow logs). | T058 step verifies flow logs after a 24h soak; per research R2 the implementer adds narrow allow rules for any legitimate destination found. |
| **Soft-deleted Key Vault blocks redeploy** | Purge protection is constitution-required; soft-deleted KVs hold their global name for the retention window. | Mitigated at v1 by deploy-time-unique 4-char `random_string` suffix on the KV name (research R7); operator runs `terraform taint random_string.deploy_suffix && terraform apply` to force a fresh suffix after a destroy. |
| **No alerting on unexpected VM downtime** | Per spec Q1, the operator detects unplanned outages on next use. Acceptable for personal single-operator scope. | v2: Azure Monitor alert rules + Action Group routing to operator email/SMS. |

---

## Customer-managed key (CMK) upgrade path

Constitution Security Constraints accepts platform-managed disk
encryption at v1 and requires this section to document the path to
customer-managed keys.

**Trigger to upgrade**: any of the following compels CMK at v2:
- Compliance regime requiring tenant-controlled key material.
- Multi-operator deploy where revoking one operator must invalidate
  their access to encrypted-at-rest data.
- Audit requirement to demonstrate key custody independent of Azure.

**Mechanism**:
1. Provision an Azure Key Vault Premium tier KV (HSM-backed) in a
   *separate* resource group from the deployment so the key survives
   `terraform destroy` of the workload.
2. Generate a key with `azurerm_key_vault_key`, RSA 4096 or HSM-backed
   curve.
3. Create a `azurerm_disk_encryption_set` referencing the key,
   identity = system-assigned MI of the disk encryption set.
4. Grant the disk encryption set's MI `Key Vault Crypto Service
   Encryption User` on the CMK Key Vault.
5. Set `disk_encryption_set_id` on the VM's `os_disk` block.
6. For Key Vault itself, set `azurerm_key_vault.key.key_type =
   "RSA-HSM"` and configure CMK at `azurerm_key_vault.encryption`.

**v1 → v2 migration is not in-place**: CMK on an existing OS disk
requires either snapshot + restore or VM rebuild. The v2 PR will
document the chosen path.

---

## Update cadence

| Event | What gets re-reviewed |
|---|---|
| PR touches network rules (NSG, VNet, subnet, service endpoint) | "Network" mitigation; egress allowlist; attacker list |
| PR touches identity / RBAC | "Identity" mitigation; principle of least privilege table |
| PR touches secret-handling code path (cloud-init scripts, `nemoclaw.service`, KV access) | "Mediation channel" mitigation; FR-007–FR-012 traceability |
| PR adds a new fetched secret beyond `foundry-api-key` | FR-011 spec amendment; new row in Assets table; new entry in attacker-reachability analysis |
| NemoClaw upstream version bump | Verify upstream's host-vs-sandbox isolation behaviour has not changed (the load-bearing mitigation) |
| Quarterly | Re-read Residual Risks; promote any v2 candidate that has become a v1 priority |

---

## Cross-references

- **Constitution Principle II** — non-negotiable secret-handling rule
  this document operationalises.
- **Constitution Security Constraints** — the source of the rules
  this document affirms compliance with.
- **Spec FR-007 through FR-012** — the secret-handling functional
  requirements this design satisfies.
- **Research R4 (revised)** — the credential-handoff design.
- **Research R10 (revised)** — the audit pipeline.
- **Research R13** — the KV network-access design.
- **Contract `credential-handoff.md`** — the systemd unit and script
  shape.
- **Contract `kv-secret-layout.md`** — the KV secret naming and tags.
