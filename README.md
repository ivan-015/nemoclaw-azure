# nemoclaw-azure

Hardened Azure deployment of [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw)
for personal, single-operator use. Tailscale-only access, no public
ingress, OpenShell-on-host inference proxy keeps provider credentials
off the agent sandbox, Azure AI Foundry as the inference provider,
auto-shutdown for cost control.

**Status**: v0.1 — first working deploy. See
[`specs/001-hardened-nemoclaw-deploy/STATUS.md`](./specs/001-hardened-nemoclaw-deploy/STATUS.md)
for what's spec'd vs. what's deployed (the architecture pivoted during
implementation when upstream NemoClaw turned out to ship a curl|bash
installer + `nemoclaw onboard` model rather than release tarballs).

## What it does, in one paragraph

`terraform apply` provisions a single Linux VM in your Azure
subscription, joined to your Tailscale tailnet (no public IP, zero
NSG inbound allow rules), with NemoClaw + OpenShell installed
non-interactively via upstream's official installer. The OpenShell
gateway on the host intercepts the agent's inference traffic at
`inference.local` and forwards to Azure AI Foundry with your API key
attached — so the OpenClaw agent inside the Landlock + seccomp + netns
sandbox never sees your provider credentials. Telegram, Discord, and
Slack channels can be enabled by re-running `nemoclaw onboard` with
the bot tokens in env. The VM auto-deallocates nightly at 21:00 PT
(configurable) to keep monthly cost in the $40–80 range depending on
how often you actually use it.

## Happy path

```bash
# 1. Bootstrap the Terraform state backend (once per subscription).
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
terraform init && terraform apply

# 2. Apply the workload (creates network + KV + identity + LA first).
cd ../root
cp examples/personal.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
terraform init -backend-config=...   # use the backend_config_block from step 1
terraform apply -target=module.network -target=module.identity \
                -target=module.keyvault -target=module.log_analytics

# 3. Seed the two real secrets in Key Vault.
KV=$(terraform output -raw key_vault_name)
az keyvault secret set --vault-name $KV --name foundry-api-key   --value '<your-foundry-key>'
az keyvault secret set --vault-name $KV --name tailscale-auth-key --value 'tskey-auth-...'

# 4. Final apply — creates the VM; cloud-init runs the upstream
#    NemoClaw installer + onboard non-interactively against your
#    Foundry endpoint.
terraform apply
```

Full walkthrough:
[`specs/001-hardened-nemoclaw-deploy/quickstart.md`](./specs/001-hardened-nemoclaw-deploy/quickstart.md).

## What this repo provisions

- One Linux VM (Ubuntu 24.04 LTS, no public IP, NSG with zero inbound
  allow rules + an explicit outbound allowlist).
- One user-assigned managed identity scoped to one Key Vault role
  (`Key Vault Secrets User` at the KV resource scope — not subscription).
- One Key Vault (RBAC mode, public network access denied by default,
  VNet service endpoint + IP allowlist for the operator's `/32`,
  soft-delete + purge protection ON).
- One Log Analytics workspace receiving Key Vault audit events and
  VNet flow logs.
- One nightly `azurerm_dev_test_global_vm_shutdown_schedule` (default
  21:00 America/Los_Angeles, opt-out via `auto_shutdown_enabled = false`).
- A single shared resource group for both the state-backend storage
  account and the workload (operator-overridable name; default
  `rg-nemoclaw`).

The full resource graph: [`specs/001-hardened-nemoclaw-deploy/data-model.md`](./specs/001-hardened-nemoclaw-deploy/data-model.md).

## VM SKU note

The default `vm_sku` in `personal.tfvars.example` is `Standard_B4als_v2`,
but Azure subscription quota varies. The validation list in
`terraform/root/variables.tf` allows `Standard_B4als_v2`,
`Standard_B4as_v2`, `Standard_B4ms`, `Standard_D4as_v5`,
`Standard_D4s_v5` — check availability in your sub via
`az vm list-skus --location <region> --resource-type virtualMachines`
and override `vm_sku` in your `terraform.tfvars` accordingly. All
allowlisted SKUs meet upstream's 4 vCPU / 8 GB minimum.

## Region default — `centralus`

| Aspect | `centralus` | `eastus2` |
|---|---|---|
| Price | comparable | comparable |
| Latency from US west coast | lower | higher |
| Latency from US east coast | higher | lower |

Override `var.location` if you prefer something else; the allowlist
covers `eastus`, `eastus2`, `centralus`, `westus2`, `westus3`,
`northeurope`, `westeurope`.

## Toolchain

- `terraform` ≥ 1.6
- `az` (Azure CLI) authenticated to the target subscription
- A Tailscale account with admin access to a tailnet you control
- An Azure AI Foundry resource with an OpenAI-compatible deployment
  (the deploy uses the `/openai/v1` compat endpoint with Bearer auth)
- For local development: `tflint`, `tfsec`, `shellcheck` (Phase 8
  lint gate; CI-equivalent runs on every PR)

## What's NOT here

This is a deliberately small, single-operator deploy. If you need any
of the following, this isn't the right starting point — fork and
extend:

- **GPU inference.** No NVIDIA-driver provisioning, no NIM container,
  no vLLM. Foundry / OpenAI / Anthropic are the supported providers.
- **Multi-operator / role separation.** The Tailscale ACL example
  uses `autogroup:owner` for everything. Separating "ops" from
  "users" requires custom group rules.
- **High availability.** Single VM. If the VM goes down, the deploy
  is down. Acceptable for personal use; not for shared services.
- **Monitoring / alerting on unexpected downtime.** No Action Groups,
  no email/SMS routing. Operator finds out when Tailscale ping fails.
- **Customer-managed encryption keys.** Platform-managed disk
  encryption at v0.1; CMK upgrade path documented in the threat model.
- **Private Endpoint for Key Vault.** VNet service endpoint suffices
  at single-VM scale.
- **Provider abstraction.** The Terraform variable surface is
  Foundry-specific (`foundry_endpoint`, `foundry_primary_deployment_key`).
  Non-Foundry users would need to fork; provider-generalization is on
  the v0.2 roadmap.

## Documentation map

| File | Purpose |
|---|---|
| [`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md) | Assets, attackers, mitigations, residual risks. The §"Mediation channel" section describes how OpenShell keeps the API key off the sandbox. |
| [`docs/TAILSCALE.md`](./docs/TAILSCALE.md) | Auth-key lifecycle, ACL recommendations, no-network debug walkthrough. |
| [`.specify/memory/constitution.md`](./.specify/memory/constitution.md) | Project constitution — every PR is reviewed against it. |
| [`specs/001-hardened-nemoclaw-deploy/STATUS.md`](./specs/001-hardened-nemoclaw-deploy/STATUS.md) | What in this directory is current vs. historical (architecture pivoted during implementation). |
| [`specs/001-hardened-nemoclaw-deploy/quickstart.md`](./specs/001-hardened-nemoclaw-deploy/quickstart.md) | Operator-facing deploy walkthrough. |
| [`terraform/bootstrap/README.md`](./terraform/bootstrap/README.md) | State-backend bootstrap docs. |
| [`SECURITY.md`](./SECURITY.md) | How to report security issues. |

## Why upstream's curl|bash + onboard?

NemoClaw doesn't ship versioned release tarballs the way most CLI
tools do — its installer is `https://www.nvidia.com/nemoclaw.sh`,
which clones the pinned tag (`NEMOCLAW_INSTALL_TAG=v0.0.26`) with
`--depth 1` and runs `scripts/install.sh` from that ref. The
reproducibility property comes from the pinned git ref, not a
SHA256-of-tarball. `nemoclaw onboard` is fully scriptable through env
vars (`NEMOCLAW_PROVIDER`, `NEMOCLAW_MODEL`, `COMPATIBLE_API_KEY`,
`NEMOCLAW_ENDPOINT_URL`, etc.) so cloud-init can drive the entire
install + sandbox creation + provider validation flow without an
operator at the keyboard.

The original v0.1 design specced a parallel JIT-tmpfs credential
handoff via a custom `nemoclaw.service` systemd unit. Once the
implementation hit upstream reality, the systemd model was retired —
NemoClaw is CLI-driven, not a daemon — and the credential-isolation
guarantee is provided by upstream's OpenShell-intercepts-on-host
design. Principle II of the constitution still holds; the mechanism
just lives a layer up. Full pivot story:
[`specs/001-hardened-nemoclaw-deploy/STATUS.md`](./specs/001-hardened-nemoclaw-deploy/STATUS.md).

## License

[Apache 2.0](./LICENSE) — matches NemoClaw upstream's license.
Copyright 2026 Ivan Vigliante.
