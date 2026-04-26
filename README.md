# nemoclaw-azure

Hardened Azure deployment of [NemoClaw](https://github.com/NVIDIA/NemoClaw)
for personal, single-operator use. Tailscale-only access, no public
ingress, brokered secrets per
[constitution Principle II](./.specify/memory/constitution.md), Azure
AI Foundry as the inference provider, auto-shutdown for cost control.

**Status**: v1 in active development (`001-hardened-nemoclaw-deploy`).

---

## Happy path (4 lines)

1. Run `terraform/bootstrap/` once with local state to create the
   remote state backend.
2. Run `terraform/root/` (first apply) — creates the Key Vault.
3. Place the Foundry API key + Tailscale auth key into Key Vault
   (`az keyvault secret set ...`).
4. Run `terraform/root/` (second apply) — completes the deploy; the VM
   joins your tailnet and `tailscale ping <vm>` succeeds.

For the full walkthrough see
[specs/001-hardened-nemoclaw-deploy/quickstart.md](./specs/001-hardened-nemoclaw-deploy/quickstart.md).

---

## What this repo provisions

- One Linux VM (Ubuntu 24.04 LTS, `Standard_B4als_v2` by default,
  no public IP, NSG with zero inbound allow rules).
- One user-assigned managed identity scoped to one Key Vault role.
- One Key Vault (RBAC mode, public access disabled, VNet service
  endpoint + network ACL, soft-delete + purge protection).
- One Log Analytics workspace receiving Key Vault audit events and
  NSG flow logs.
- One nightly `azurerm_dev_test_global_vm_shutdown_schedule` (default
  21:00 America/Los_Angeles, opt-out via `auto_shutdown_enabled = false`).

The full resource graph and rationale lives in
[`specs/001-hardened-nemoclaw-deploy/data-model.md`](./specs/001-hardened-nemoclaw-deploy/data-model.md)
and [`plan.md`](./specs/001-hardened-nemoclaw-deploy/plan.md).

---

## Region default — `centralus`

The default region is `centralus`, not the constitution's named
`eastus2` example. Trade-off:

| Aspect | `centralus` | `eastus2` |
|---|---|---|
| Price | comparable | comparable |
| Latency from US west coast | lower | higher |
| Latency from US east coast | higher | lower |
| Co-location with operator's existing personal infra | yes | no |

Constitution Cost & Operational Constraints permits the operator to
override the region default, and that's what the default does here.
Override per `var.location` if you prefer `eastus2` or another
allowlisted region (`eastus`, `centralus`, `eastus2`, `westus2`,
`westus3`, `northeurope`, `westeurope`).

---

## Toolchain

- `terraform` ≥ 1.6 — install via your package manager or
  [tfenv](https://github.com/tfutils/tfenv).
- `az` (Azure CLI) — authenticated to your personal subscription.
- A Tailscale account with admin access to the tailnet you want this
  VM to join.
- An Azure AI Foundry instance (separate Azure subscription preferred
  per spec assumptions) with an OpenAI-compatible endpoint and a key
  scoped to *this* deployment (not the production key).
- (Phase 8 lint gate) `tflint`, `tfsec`, `shellcheck` — install
  locally before opening the v1 PR.

---

## Documentation map

| File | Purpose |
|---|---|
| [`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md) | Assets, attackers, mitigations, residual risks (constitution Security Constraints requires this). |
| [`docs/TAILSCALE.md`](./docs/TAILSCALE.md) | Auth-key lifecycle, ACL recommendations, no-network debug walkthrough. |
| [`.specify/memory/constitution.md`](./.specify/memory/constitution.md) | Project constitution v1.0.0 — every PR is reviewed against it. |
| [`specs/001-hardened-nemoclaw-deploy/spec.md`](./specs/001-hardened-nemoclaw-deploy/spec.md) | Functional spec for v1. |
| [`specs/001-hardened-nemoclaw-deploy/plan.md`](./specs/001-hardened-nemoclaw-deploy/plan.md) | Implementation plan. |
| [`specs/001-hardened-nemoclaw-deploy/quickstart.md`](./specs/001-hardened-nemoclaw-deploy/quickstart.md) | Operator-facing deploy walkthrough. |
| [`terraform/bootstrap/README.md`](./terraform/bootstrap/README.md) | State-backend bootstrap docs. |

---

## Status / non-goals at v1

- Single VM, single operator, single environment.
- No multi-region, no HA, no monitoring/alerting on unexpected
  downtime — operator detects unplanned outages on next use.
- No customer-managed encryption keys (platform-managed at v1; CMK
  upgrade path documented in `docs/THREAT_MODEL.md`).
- No Private Endpoint for Key Vault (VNet service endpoint suffices
  at single-VM scale; PE is a v2 upgrade if multiple consumers
  appear).

The full v1 scope and the v2 backlog live at the bottom of
[`spec.md`](./specs/001-hardened-nemoclaw-deploy/spec.md).

---

## License

TBD. The project is intended for open-source release under a
permissive license once v1 ships.
