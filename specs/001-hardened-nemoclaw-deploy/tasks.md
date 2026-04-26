# Tasks: Hardened NemoClaw Azure Deployment (v1)

**Input**: Design documents from `specs/001-hardened-nemoclaw-deploy/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, contracts/*, quickstart.md
**Constitution**: [v1.0.0](../../.specify/memory/constitution.md)

**Tests**: Terraform is validated via `terraform validate`, `tflint`,
`tfsec`. Shell scripts (cloud-init + credential handoff) are validated
via `shellcheck` plus integration testing in the runnable
`scripts/verify.sh` suite (`contracts/verification-checks.md`). E2E
test = the apply + verify loop on a throwaway RG. **Note (2026-04-25)**:
the original plan included a Go broker requiring ≥80% unit-test
coverage; the broker was removed per spec Q4 (NemoClaw upstream's own
host-vs-sandbox isolation makes it redundant). No first-party Go
service is in v1, so no Go test coverage requirement.

**Organization**: Tasks are grouped by user story to enable independent
implementation and testing. Each user-story phase is a complete,
independently-verifiable increment.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on
  incomplete tasks in this list)
- **[Story]**: Maps to spec.md user stories (US1, US2, US3, US4, US5)
- File paths are absolute under the repo root.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repo scaffolding and tooling configuration. No feature
behavior yet.

- [ ] T001 Create the directory tree per `plan.md` §"Source Code (repository root)": `terraform/bootstrap/`, `terraform/root/{modules/{network,identity,keyvault,log-analytics,vm},examples}`, `cloud-init/scripts`, `scripts/`, `docs/`.
- [ ] T002 [P] Append `.gitignore` entries for Terraform (`**/.terraform/`, `**/terraform.tfstate*`, `**/*.tfvars` except `*.example`, keep `**/.terraform.lock.hcl`), and editor noise (`*.swp`, `.DS_Store`).
- [ ] T003 [P] Create `terraform/bootstrap/providers.tf` with `terraform { required_version = ">= 1.6" }` and `azurerm ~> 4.x` provider pin (no backend block — bootstrap uses local state).
- [ ] T004 [P] Create `terraform/root/providers.tf` with `terraform { required_version = ">= 1.6", backend "azurerm" {} }` (backend config supplied via `-backend-config` at `terraform init`) and `azurerm ~> 4.x` provider pin.
- [ ] T005 [P] Create `.tflint.hcl` at repo root with the `azurerm` ruleset enabled.
- [ ] T006 [P] Create `.tfsec.yml` at repo root listing intentionally-accepted exception IDs (none expected at v1 — file may be empty with a comment).
- [ ] T007 [P] Add `shellcheck` to the recommended toolchain (no config file needed; just document running it in `README.md` and Phase 8).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Documents and Terraform skeletons that every user story
depends on. **No user-story work begins until this phase is complete.**

- [ ] T008 Create `docs/THREAT_MODEL.md` per constitution Security Constraints — sections: Assets (NemoClaw host process, sandboxed agent, Foundry API key, Tailscale auth key, VM disk, Key Vault), Attackers (prompt-injected agent, lateral mover, lost laptop, compromised CI), Mitigations (NemoClaw upstream's host-vs-sandbox isolation as the principal Principle II mitigation; the credential handoff `ExecStartPre` + tmpfs + `EnvironmentFile=` pattern as the constitution-named mediation channel; Tailscale-only ingress; KV service endpoint + network ACL; managed identity scope), Residual risks (NemoClaw zero-day, Tailscale account compromise, NemoClaw host-process memory still holds the key for its lifetime, persisted KV-side Tailscale auth key for 24h, manual Tailscale node revocation on destroy), Customer-managed key upgrade path (constitution requirement), update cadence.
- [ ] T009 [P] Create `docs/TAILSCALE.md` — auth-key generation parameters (reusable=false, ephemeral=true, pre-approved, expiry=24h, tag=`tag:nemoclaw`), KV pre-staging procedure, ACL recommendation snippet, manual node-revocation step on `terraform destroy`, reliance on Tailscale's 24h ephemeral expiry as the v1 mitigation for the persisted KV value, no-network debug walkthrough using `az vm run-command`.
- [ ] T010 Implement `terraform/bootstrap/main.tf` — provisions a resource group, storage account (`public_network_access_enabled=false`, `shared_access_key_enabled=false`, `min_tls_version="TLS1_2"`, blob versioning enabled), and blob container for state. Storage account name uses a 4-char `random_string` suffix. **Apply the four mandatory tags** (`project="nemoclaw-azure"`, `owner=var.owner`, `cost-center="personal"`, `managed-by="terraform"`) to the RG and the storage account — bootstrap is in a separate Terraform state from `root/`, so it cannot consume `terraform/root/locals.tf`; instead define a small `local.mandatory_tags` block in `terraform/bootstrap/locals.tf` (new file) and apply it. Required by spec FR-020 ("every Azure resource").
- [ ] T011 [P] Implement `terraform/bootstrap/variables.tf` — `subscription_id`, `location` (default `centralus`), `owner` (no default).
- [ ] T012 [P] Implement `terraform/bootstrap/outputs.tf` emitting `storage_account_name`, `resource_group_name`, `container_name`, plus a printable `backend_config_block` string for copy/paste into `terraform init -backend-config`.
- [ ] T013 [P] Create `terraform/bootstrap/README.md` documenting the chicken-and-egg, the recovery path (`terraform refresh -refresh-only` + `terraform import` if local state is lost), and that the local state file is gitignored and must be backed up.
- [ ] T014 [P] Create `terraform/bootstrap/terraform.tfvars.example` with placeholder values.
- [ ] T015 Implement `terraform/root/locals.tf` — `random_string.deploy_suffix` (length=4, lower+digits), mandatory tags map (`project="nemoclaw-azure"`, `owner=var.owner`, `cost-center=var.cost_center`, `managed-by="terraform"`), merged tags = `merge(var.tags, local.mandatory_tags)`, derived names (KV name, MI name) using the suffix.
- [ ] T016 Implement `terraform/root/variables.tf` — every variable in `contracts/tfvars-inputs.md` with type, default, and `validation` blocks (subscription GUID pattern, region allowlist, SKU allowlist, `nemoclaw_version` semver pattern rejecting `main`/`latest`, `foundry_endpoint` `https://` prefix, non-empty `foundry_deployments`, `tailscale_tag` pattern, `auto_shutdown_local_time` HH:MM, IANA tz allowlist, owner email-or-handle pattern).
- [ ] T017 [P] Implement `terraform/root/outputs.tf` shell — empty placeholders for `vm_tailnet_hostname`, `vm_resource_id`, `vm_name`, `resource_group_name`, `key_vault_uri`, `key_vault_name`, `log_analytics_workspace_id`, `start_command` (filled in by later phases).
- [ ] T018 [P] Create `README.md` at repo root — happy path (4-line summary linking to `quickstart.md`), constitution-required region trade-off note (centralus vs eastus2), link to `docs/THREAT_MODEL.md`, link to constitution.

**Checkpoint**: Foundation ready — user-story implementation can now begin.

---

## Phase 3: User Story 1 — Stand up a working, reachable NemoClaw (P1) 🎯 MVP

**Goal**: A single `terraform apply` (after `bootstrap/`) provisions the
entire stack, NemoClaw is installed at the pinned version, and the
operator can `tailscale ping <vm>` + run `nemoclaw doctor` from a
tailnet-joined laptop. NemoClaw's systemd unit is in place but not yet
configured to fetch the Foundry key — the credential handoff is added
in US2 so US1 can deliver "VM up, hardened, NemoClaw self-check passes"
as an independent slice.

**Independent Test**: From a tailnet-joined laptop, `tailscale ping <vm>`
succeeds and `tailscale ssh <vm> -- nemoclaw doctor` exits 0.

### Implementation for User Story 1

- [ ] T019 [P] [US1] Implement `terraform/root/modules/network/main.tf` — VNet (`10.x.0.0/24`), subnet `vm` (`10.x.0.0/27`) with `service_endpoints = ["Microsoft.KeyVault"]`, NSG with **zero inbound allow rules** plus an outbound allowlist (per research R2: `AzureActiveDirectory`, `AzureKeyVault.<region>`, `Storage.<region>`, `MicrosoftContainerRegistry`, `AzureFrontDoor.FirstParty`, `CognitiveServicesManagement.<region>`, Tailscale FQDNs + UDP/41641, Ubuntu mirrors, NodeSource), NSG association on the `vm` subnet, separate `nsgflowlogs` storage account, Network Watcher Flow Log resource targeting it. Module variables/outputs per `data-model.md` §3. **No `private-endpoints` subnet** at v1 (per research R13 — service endpoint replaces PE).
- [ ] T020 [P] [US1] Implement `terraform/root/modules/identity/main.tf` — `azurerm_user_assigned_identity` named via `local.mi_name`, output the principal_id and client_id for downstream RBAC binding.
- [ ] T021 [P] [US1] Implement `terraform/root/modules/log-analytics/main.tf` — workspace with retention ≥ 30 days. **No custom DCR for broker journald** (broker removed); Key Vault diagnostic settings (created in T022) ship audit events here directly.
- [ ] T022 [US1] Implement `terraform/root/modules/keyvault/main.tf` — KV with `sku_name="standard"`, `enable_rbac_authorization=true`, `public_network_access_enabled=false`, `purge_protection_enabled=true`, `soft_delete_retention_days=7`, name uses `local.kv_name` (suffix). **`network_acls`** block: `default_action="Deny"`, `bypass="AzureServices"`, `virtual_network_subnet_ids=[vm_subnet_id]` (no Private Endpoint per R13). RBAC role assignment: managed identity gets `Key Vault Secrets User` at the KV resource scope. Diagnostic settings → log analytics workspace (`AuditEvent` + `AllMetrics`). Two `azurerm_key_vault_secret` resources for `foundry-api-key` and `tailscale-auth-key` with **placeholder values** (operator overwrites them between the staged applies — see `quickstart.md` step 3); both tagged per `contracts/kv-secret-layout.md`. Depends on T019 (subnet) and T020 (identity).
- [ ] T023 [P] [US1] Cloud-init script `cloud-init/scripts/01-tailscale.sh` — install `tailscale` from the official Linux repo, install `azure-cli`, fetch the `tailscale-auth-key` from KV using the VM's managed identity (`az login --identity` + `az keyvault secret show --query value -o tsv`), run `tailscale up --authkey="$key" --ssh=true --advertise-tags=tag:nemoclaw --hostname=<deterministic>`, then unset the variable AND clear the cloud-init log lines that contain it (overwrite with `xxx`s). Fail-loud on any error.
- [ ] T024 [P] [US1] Cloud-init script `cloud-init/scripts/02-docker.sh` — install Docker CE from `https://download.docker.com/linux/ubuntu`, pin to a specific version (parameterized via cloud-init template var), enable + start the daemon.
- [ ] T025 [P] [US1] Cloud-init script `cloud-init/scripts/03-node.sh` — install Node 22.16+ via NodeSource (`https://deb.nodesource.com/setup_22.x`), pin minor.
- [ ] T026 [US1] Cloud-init script `cloud-init/scripts/05-nemoclaw.sh` — download NemoClaw release tarball at `${nemoclaw_version}` from the official GitHub Release URL (`https://github.com/NVIDIA/NemoClaw/releases/download/${nemoclaw_version}/nemoclaw-${nemoclaw_version}.tar.gz`); fetch the matching `.sha256` file from the same release and verify before extraction (fail-loud on mismatch). Run unattended install per research R1 (try config-file/env hooks first; fall back to `expect` if needed). Configure NemoClaw's runtime config with `${foundry_endpoint}`, `${foundry_deployments}` (rendered as JSON), `${foundry_api_version}`. **Do NOT write any secret to NemoClaw's config**. Create `nemoclaw` system user + group. **Create `cloud-init/scripts/nemoclaw.service.tpl` as a new file** with the US1 placeholder content: `ExecStartPre=/bin/true`, `ExecStart=/usr/local/bin/openshell …`, the hardening directives, `[Install] WantedBy=multi-user.target` — leaving `EnvironmentFile=` and the real `ExecStartPre` for T033 to add in US2. The rendered output of this template (via Terraform `templatefile()` in T031) is dropped to `/etc/systemd/system/nemoclaw.service` by cloud-init `write_files`. `systemctl enable nemoclaw.service` (do **not** start it yet — it has no API key). Smoke-test `nemoclaw doctor` (or upstream's documented health command) before exiting.
- [ ] T027 [US1] Cloud-init template `cloud-init/bootstrap.yaml.tpl` — `runcmd:` invoking **the five scripts in order**: `01-tailscale.sh` → `02-docker.sh` → `03-node.sh` → `04-credential-handoff.sh` (installs the `/usr/local/bin/nemoclaw-credential-handoff` binary + `/etc/tmpfiles.d/nemoclaw.conf`; the binary itself runs later as `ExecStartPre`, but it must be installed at cloud-init time) → `05-nemoclaw.sh`. `write_files:` includes (a) `nemoclaw-answers.expect` if needed, and (b) the **rendered** systemd unit content — produced by `templatefile("cloud-init/scripts/nemoclaw.service.tpl", { kv_name = ..., foundry_endpoint = ..., ... })` at Terraform render time, NOT the raw `.tpl` file (cloud-init's `write_files` doesn't expand Terraform interpolations) — destination `/etc/systemd/system/nemoclaw.service`. The whole bootstrap.yaml.tpl is itself rendered with Terraform `templatefile()` substitutions for `kv_uri`, `kv_name`, `nemoclaw_version`, `foundry_endpoint`, `foundry_deployments`, `foundry_api_version`, `tailscale_tag`.
- [ ] T028 [US1] Implement `terraform/root/modules/vm/main.tf` — `azurerm_linux_virtual_machine` with: image `Canonical/ubuntu-24_04-lts/server/<pinned-version>`, `size = var.vm_sku`, `disable_password_authentication=true`, no `admin_ssh_key` (Tailscale SSH only), `identity { type="UserAssigned", identity_ids=[var.managed_identity_id] }`, `os_disk` with platform-managed encryption, `custom_data = base64encode(rendered_cloud_init)`, `boot_diagnostics { storage_account_uri = null }` (managed diagnostics), no public IP on the NIC, NIC in the `vm` subnet, depends on the cloud-init template render and the KV (so cloud-init can read the Tailscale auth key on first boot).
- [ ] T029 [US1] Wire all modules in `terraform/root/main.tf` — call network → identity → log-analytics → keyvault → vm in dependency order, pass outputs through, fill `terraform/root/outputs.tf` with the values from each module.
- [ ] T030 [P] [US1] Create `terraform/root/examples/personal.tfvars.example` per `contracts/tfvars-inputs.md` §Examples (subscription_id placeholder, location=centralus, vm_sku=Standard_B4als_v2, foundry_endpoint placeholder, foundry_deployments map, owner placeholder).
- [ ] T031 [US1] Implement initial `scripts/verify.sh` — pre-flight (0a–0c) + SC-002 (apply timing) + SC-003 (NSG / no-public-IP / nmap from outside) + SC-001 (tailscale ping + Tailscale SSH `nemoclaw doctor`) per `contracts/verification-checks.md`. Exit non-zero on any failure. Emit a per-check pass/fail line.

**Checkpoint**: After Phase 3, US1 acceptance scenarios all pass.
NemoClaw is installed and `nemoclaw doctor` succeeds. The systemd
unit is present but disabled-from-running until US2 wires the
credential handoff.

---

## Phase 4: User Story 2 — Sandboxed agent never sees a static secret (P1)

**Goal**: NemoClaw's systemd unit runs the credential handoff
`ExecStartPre` script on every start, fetches the Foundry API key from
KV via managed identity, transits it through a tmpfs file consumed via
`EnvironmentFile=`, and unlinks the file before steady state. NemoClaw
performs a real inference call. The sandboxed agent's environ,
cmdline, and persisted config contain **zero** matches against the KV
value. Key Vault diagnostic logs in Log Analytics record every
`SecretGet`.

**Independent Test**: Run a real inference call → confirm success;
identify the sandboxed agent PID per NemoClaw's documented command;
`grep` the foundry-api-key value across `/proc/<agent-pid>/environ`,
`/proc/<agent-pid>/cmdline`, `/var/lib/nemoclaw/`, `/etc/nemoclaw/`,
and `/run/nemoclaw/` → zero matches; query `AzureDiagnostics` in
Log Analytics for `OperationName == "SecretGet"` → audit record exists.

### Implementation for User Story 2

- [ ] T032 [US2] Cloud-init script `cloud-init/scripts/04-credential-handoff.sh` — installs `/usr/local/bin/nemoclaw-credential-handoff` per `contracts/credential-handoff.md`. The script runs `az login --identity` (idempotent), fetches `foundry-api-key` from KV, writes `OPENAI_API_KEY=<value>\n` to `/run/nemoclaw/env` via `install -m 0400 -o nemoclaw -g nemoclaw`, then unsets the local variable. Exit non-zero with a journald error if any step fails. Also write `/etc/tmpfiles.d/nemoclaw.conf` = `d /run/nemoclaw 0750 root nemoclaw -` so the directory exists pre-systemd.
- [ ] T033 [US2] Update `cloud-init/scripts/05-nemoclaw.sh` and the templated systemd unit (`cloud-init/scripts/nemoclaw.service.tpl`) to add the full credential-handoff wiring per `contracts/credential-handoff.md`: `ExecStartPre=/usr/local/bin/nemoclaw-credential-handoff` (replacing the US1 placeholder), `Environment=KV_NAME=${kv_name}`, `Environment=FOUNDRY_SECRET_NAME=foundry-api-key`, `Environment=OUT_FILE=/run/nemoclaw/env`, `EnvironmentFile=/run/nemoclaw/env`, `ExecStartPost=/bin/rm -f /run/nemoclaw/env`, plus the hardening directives (`ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `NoNewPrivileges=true`, `ReadWritePaths=/run/nemoclaw /var/lib/nemoclaw`). At end of cloud-init, `systemctl daemon-reload && systemctl start nemoclaw.service`.
- [ ] T034 [US2] Update `scripts/verify.sh` with US2 checks per `contracts/verification-checks.md`: SC-004 (4a–4e — including locating the *sandboxed agent* PID via NemoClaw's documented command, confirming `/run/nemoclaw/env` is gone, and grepping the agent process's environ/cmdline/persisted-config for the KV value), SC-008 (audit landing — restart NemoClaw, query `AzureDiagnostics` for `SecretGet` within 5 min), EC-2 (Foundry key rotation propagates after `systemctl restart`), EC-4 (tmpfs handoff file unlinked promptly), EC-5 (handoff cannot fetch tailscale-auth-key). The Principle II tooth-check is **load-bearing** — verify.sh exits non-zero if 4c/4d/4e match.
- [ ] T035 [US2] Run end-to-end against a throwaway RG: apply, restart NemoClaw to trigger fresh credential fetch, run real inference, run verify.sh. Document the output as the v1 PR artifact.

**Checkpoint**: After Phase 4, US2 acceptance scenarios all pass. The
deployment is now functionally complete for inference. US3–US5 add
operational polish, debug paths, and clean teardown.

---

## Phase 5: User Story 3 — Cost-controlled overnight operation (P2)

**Goal**: VM auto-deallocates at 21:00 PT daily; operator can wake it
with a single `az vm start` command from their workstation; verified
monthly cost lands within the spec's $40 / $80 envelope.

**Independent Test**: Wait for the next 21:00 PT or trigger manually;
confirm `az vm get-instance-view` reports `PowerState/deallocated`
within 10 min; run `az vm start`; confirm Tailscale-reachable + service
healthy within 5 min.

### Implementation for User Story 3

- [ ] T036 [US3] Add `azurerm_dev_test_global_vm_shutdown_schedule` to `terraform/root/main.tf` (top-level resource, not in vm module — keeps the vm module reusable for non-personal profiles). Wired with: `daily_recurrence_time = replace(var.auto_shutdown_local_time, ":", "")`, `timezone = var.auto_shutdown_tz`, `notification_settings { enabled=false }` (per spec Q1: no alerting in v1), `count = var.auto_shutdown_enabled ? 1 : 0`.
- [ ] T037 [US3] Add `start_command` output to `terraform/root/outputs.tf` — a printable `az vm start --resource-group <rg> --name <vm>` ready for copy/paste; convenience for the operator after auto-shutdown. Also fill in `vm_name` and `resource_group_name` raw outputs from the placeholders T017 created. (Not [P] — same file as T038 was; folded into one task to avoid same-file coordination overhead.)
- [ ] T038 [US3] *(Removed — folded into T037 above to avoid same-file [P] coordination.)*
- [ ] T039 [P] [US3] Update `terraform/root/examples/personal.tfvars.example` to confirm defaults result in auto-shutdown ON at 21:00 America/Los_Angeles.
- [ ] T040 [P] [US3] Create `terraform/root/examples/dev.tfvars.example` — same as personal but `auto_shutdown_enabled = false` for active iteration days.
- [ ] T041 [US3] Update `scripts/verify.sh` with US3 checks: SC-005 (printable cost reminder pointing the operator at the Cost Management view), SC-006 (after 21:10 PT, verify `PowerState/deallocated`), SC-007 (timed start-to-tailscale-reachable loop). The cost check is *advisory only* (verify.sh prints the Azure portal URL — the actual cost lookup is interactive).
- [ ] T042 [P] [US3] Update `quickstart.md` §7 ("Daily life") to confirm the wake-up flow matches the implementation; ensure the documented `az vm start` command is the same string as the `start_command` output.

**Checkpoint**: After Phase 5, US3 acceptance scenarios pass.
Deployment is cost-controlled.

---

## Phase 6: User Story 4 — Operator can debug a broken deployment without exposing the network (P2)

**Goal**: When Tailscale or NemoClaw is misbehaving, the operator can
investigate via Azure-control-plane paths (`az vm run-command`, serial
console) without opening any inbound port. Mostly documentation —
the capabilities themselves are inherent to the VM provisioning done
in US1.

**Independent Test**: With Tailscale daemon manually stopped on the
VM, `az vm run-command invoke --command-id RunShellScript --scripts
"systemctl start tailscaled"` succeeds and brings Tailscale back.

### Implementation for User Story 4

- [ ] T043 [P] [US4] Verify boot diagnostics enabled in `terraform/root/modules/vm/main.tf` (managed boot diagnostics — already required by T028; this task is a code-review checkpoint).
- [ ] T044 [P] [US4] Expand `quickstart.md` §8 ("Troubleshooting") with the no-network debug walkthrough: how to read cloud-init logs via Run Command, how to attach to serial console via the Azure portal, how to read journald for `nemoclaw.service` via Run Command, how to recover from a broken Tailscale install.
- [ ] T045 [P] [US4] Add a manual-test step to `scripts/verify.sh` (printed warning, doesn't auto-run): "EC-debug: stop tailscaled on VM via Run Command, confirm Run Command still functional, restart tailscaled via Run Command." Documented as an operator's-manual smoke test, not part of the auto-run suite.
- [ ] T046 [P] [US4] Update `docs/TAILSCALE.md` with a "When Tailscale itself is broken" section pointing to Run Command + serial console as the recovery path.

**Checkpoint**: After Phase 6, US4 acceptance scenarios pass.

---

## Phase 7: User Story 5 — `terraform destroy` leaves no residue that blocks the next deploy (P3)

**Goal**: `terraform destroy` removes everything; the deploy-time-unique
suffix mechanism (research R7) means a follow-up `terraform apply` with
`taint random_string.deploy_suffix` succeeds even after a soft-deleted
Key Vault would otherwise block re-creation. Tailscale auth-key persists
in KV until its 24h Tailscale-side expiry — no `null_resource` purge at
v1 (per user trim #4).

**Independent Test**: After a successful apply, run `terraform
destroy` → exits 0, RG is empty; manually revoke the node in the
Tailscale admin console (per R5); `terraform taint
random_string.deploy_suffix && terraform apply` produces a fresh KV
name and succeeds.

### Implementation for User Story 5

- [ ] T047 [P] [US5] Confirm `random_string.deploy_suffix` from T015 is correctly consumed by KV name (T022) and any other globally-unique resource (storage account in `bootstrap/` is a separate state and uses its own suffix).
- [ ] T048 [P] [US5] Update `quickstart.md` §7 ("Tearing down") with the destroy → manual Tailscale node revocation → `taint suffix` → re-apply flow.
- [ ] T049 [P] [US5] Update `docs/TAILSCALE.md` "On destroy" section with the manual node-revocation step. Document the v1 reliance on the 24h Tailscale auth-key expiry as the mitigation for the persisted-in-KV value (no null_resource purge at v1).
- [ ] T050 [US5] Update `scripts/verify.sh` with SC-009 — destroy/redeploy check (manual subtask: prints the recommended sequence, runs against a `--throwaway-rg` flag if given).

**Checkpoint**: After Phase 7, all five user stories' acceptance
scenarios pass. v1 is feature-complete.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Final pass before the v1 PR. Everything must pass before
opening.

- [ ] T051 [P] Run `terraform fmt -recursive` across `terraform/` — must produce no diff.
- [ ] T052 [P] Run `terraform validate` in `terraform/bootstrap/` and `terraform/root/` — must exit 0 in both.
- [ ] T053 [P] Run `tflint --init && tflint -f compact` at repo root — address every finding (no skips at v1).
- [ ] T054 [P] Run `tfsec .` at repo root — address every finding or document the exception in `.tfsec.yml` with rationale.
- [ ] T055 [P] Run `shellcheck cloud-init/scripts/*.sh scripts/*.sh` — address every finding (no skips).
- [ ] T056 Final pass on `README.md` for open-source-readiness — search for and remove any subscription IDs, tenant IDs, principal IDs, IP CIDRs, owner email values, or other operator-specific identifiers that may have leaked from local testing. Confirm only placeholder values remain.
- [ ] T057 Final pass on `docs/THREAT_MODEL.md` to reflect any drift discovered during implementation. Specifically: confirm the threat model accurately describes the credential-handoff `ExecStartPre` + tmpfs + `EnvironmentFile=` pattern, the residual risk window of the tmpfs file's existence (typically < 1 second between ExecStartPre and ExecStartPost), and the residual risk that NemoClaw's host process holds the key in its environ for its lifetime (mitigated by NemoClaw upstream's host-vs-sandbox isolation).
- [ ] T058 Run the full `scripts/verify.sh` end-to-end against a fresh deploy in a throwaway RG — capture every check's pass/fail line. Constitution governance (NemoClaw upstream version-bump rule) requires this for v1 as well.
- [ ] T059 Open the v1 PR with the constitution-mandated affirmation block in the description per `contracts/verification-checks.md` §"Reporting" — Constitution principles I–V reviewed; verification SC-001–SC-009 + US1-1–4 + EC-1, EC-2, EC-4, EC-5 status; LA audit sample link; cost forecast; verified NemoClaw version; region; SKU. Branch sits open ≥ 24 hours per constitution Governance §"24-hour cool-off for security-affecting changes" (this PR touches identity, network, secrets — every cool-off trigger).

---

## Dependencies & Story Completion Order

```text
Phase 1 (Setup) ─▶ Phase 2 (Foundational) ─▶ Phase 3 (US1 MVP)
                                              │
                                              ├─▶ Phase 4 (US2)  ──╮
                                              │                    │
                                              ├─▶ Phase 5 (US3)  ──┤
                                              │                    │
                                              ├─▶ Phase 6 (US4)  ──┤
                                              │                    │
                                              └─▶ Phase 7 (US5)  ──┤
                                                                    │
                                                       Phase 8 (Polish) + v1 PR
```

- **Setup** (Phase 1) and **Foundational** (Phase 2) are strict
  prerequisites for every story.
- **US1 (MVP)** must complete before US2 — US2 enables the credential
  handoff that turns the installed-but-idle NemoClaw service into a
  fully functional one.
- **US2** must complete before declaring the deployment usable for
  inference. Without US2, NemoClaw is installed but its systemd unit
  has no Foundry API key.
- **US3, US4, US5** are largely independent of each other after US1.
  They can be implemented in any order or in parallel by different
  developers/agents, but each consumes outputs from the modules created
  in US1 (`vm_id`, `resource_group_name`, etc.).
- **Polish (Phase 8)** is the gate to opening the v1 PR.

## Parallel Execution Opportunities

Within a phase, tasks marked `[P]` operate on independent files and
have no inter-task dependencies. Suggested parallel batches:

**Phase 1 setup**: T002, T003, T004, T005, T006, T007 — six parallel
file-create tasks after T001 finishes.

**Phase 2 foundational**: T009, T011, T012, T013, T014, T017, T018 —
seven parallel doc/spec tasks. T008, T010, T015, T016 are sequential
within them.

**Phase 3 (US1)**: T019, T020, T021, T023, T024, T025, T030 — seven
parallel module/script tasks. T022 (keyvault) waits on T019 (subnet)
and T020 (identity). T026, T027, T028, T029, T031 are sequential at
the end of the phase.

**Phase 4 (US2)**: T032, T033, T034 are sequential (each builds on the
prior); T035 is the final smoke test. **No TDD test tasks** — there's
no Go service to unit-test; verification is via the integration
`scripts/verify.sh` SC-004 tooth-check.

**Phase 5 (US3)**: T037, T038, T039, T040, T042 — five parallel.
T036, T041 are the sequential anchors.

**Phase 6 (US4)**: T043, T044, T045, T046 — four parallel doc tasks.

**Phase 7 (US5)**: T047, T048, T049 — three parallel doc tasks.
T050 is the sequential anchor.

**Phase 8 (Polish)**: T051–T055 — five parallel lint/format tasks.
T056, T057, T058, T059 are sequential at the end.

## Implementation Strategy: MVP First

The recommended delivery order:

1. **Setup + Foundational** (Phases 1+2) — non-negotiable starting
   point.
2. **US1 MVP** (Phase 3) — first deployable artifact. End state:
   "I have a hardened, Tailscale-reachable VM with NemoClaw installed."
   Verify, declare US1 done, optionally tag `v0.1.0-pre`.
3. **US2** (Phase 4) — second deployable artifact. End state:
   "NemoClaw can perform inference, and Principle II is verifiably
   satisfied." This is the project's *raison d'être*; consider tagging
   `v0.1.0-rc` here.
4. **US3, US4, US5** (Phases 5–7) — delivered in any order. US3 first
   is recommended since cost control is the highest-value polish.
5. **Polish** (Phase 8) → v1 PR → 24-hour cool-off → self-merge → tag
   `v0.1.0`.

After v0.1.0, the spec's "Out of Scope (v1)" backlog becomes the v2
roadmap.

---

## Task counts

- Phase 1 (Setup): 7 tasks
- Phase 2 (Foundational): 11 tasks
- Phase 3 (US1 MVP): 13 tasks
- Phase 4 (US2): 4 tasks (was 16; broker removal cut 12)
- Phase 5 (US3): 6 active tasks (T038 folded into T037 post-analyze)
- Phase 6 (US4): 4 tasks
- Phase 7 (US5): 4 tasks (was 5; null_resource purge removed)
- Phase 8 (Polish): 9 tasks (was 11; Go test/lint tasks removed)

**Total: 58 active tasks** spanning task IDs T001 → T059 (T038 is a
"folded" stub kept for audit trail). Down from 78 in the pre-pivot
plan. ~600 lines of Go avoided.

Per user story: US1=13, US2=4, US3=6, US4=4, US5=4. Setup+Foundational+Polish=27.
