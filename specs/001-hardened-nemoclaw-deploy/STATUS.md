# Spec Status — Architecture Pivot Notice

**TL;DR**: The specs in this directory describe the v0.1 design.
v0.1 was retired during implementation. The live architecture is
substantially different. Use this directory for the audit trail; use
[`../../docs/THREAT_MODEL.md`](../../docs/THREAT_MODEL.md) for the
current security model and [`../../README.md`](../../README.md) for
the current operator flow.

## What changed

The v0.1 spec described a deploy that:

- Ran NemoClaw as a `nemoclaw.service` systemd unit.
- Brokered the Foundry API key via an `ExecStartPre=` script that
  fetched it from Key Vault and wrote it to a mode-`0400` tmpfs file
  (`/run/nemoclaw/env`) consumed via systemd `EnvironmentFile=`,
  unlinked by `ExecStartPost=` before the service reached steady
  state. The intent was to satisfy the constitution's Principle II
  example ("just-in-time tmpfs file with restrictive permissions
  deleted after use").
- Verified the Principle II tooth-check by grepping the systemd unit
  process tree for the KV value.

When the implementation pivoted to upstream NemoClaw's actual install
path (`curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash`), it
became clear that:

1. **NemoClaw is not a daemon.** It's a CLI that manages an
   OpenShell-managed sandbox container; there is no `nemoclaw.service`.
2. **OpenShell intercepts inference traffic on the host.** The agent
   inside the sandbox talks to a local hostname `inference.local`;
   OpenShell forwards to the actual provider (Foundry / OpenAI /
   etc.) with the credential injected. The sandbox cannot reach the
   provider directly — sandbox isolation is enforced at the
   network-namespace + filesystem-policy boundary, not by withholding
   the credential from a shared environ.
3. **The credential persists on the host.** After `nemoclaw onboard`,
   the API key lives in `~/.nemoclaw/credentials.json` (mode `0600`,
   operator-only). This is upstream's expected pattern.

The Principle II goal — *"the sandboxed agent never sees the secret
value"* — still holds, but the mechanism is upstream's namespace +
policy boundary rather than the JIT-tmpfs handoff this spec described.

## What this means for the documents in this directory

| Document | Status | Reading guidance |
|---|---|---|
| `spec.md` | Historical | Describes v0.1 user stories. The capability + cost goals (US3, US4, US5) still hold; the credential-handoff implementation (US2 specifics) does not. |
| `plan.md` | Historical | Phase plan for v0.1. Most of the modules (network, identity, KV, LA, VM, auto-shutdown) shipped; the systemd-unit + `04-credential-handoff.sh` modules were retired. |
| `research.md` | Historical | Decision record for v0.1. The trade-offs around Tailscale + KV + cost are still load-bearing; the ones around systemd + tmpfs are not. |
| `data-model.md` | Mostly current | The Azure resource graph is still accurate. Drop the `nemoclaw.service` references. |
| `tasks.md` | Historical | Phase-by-phase task breakdown. The architecture pivot landed as commits `afd4956` + `d589097` after Phase 8. |
| `quickstart.md` | **Current** | Updated post-pivot to reflect the actual operator flow. |
| `contracts/credential-handoff.md` | **Marked superseded** in the file itself. |
| `contracts/kv-secret-layout.md` | Mostly current | The KV layout (one secret per provider credential) is unchanged. |
| `contracts/verification-checks.md` | Partially current | SC-001/002/003/005/006/007/008/009 still apply; SC-004 was rewritten to match the OpenShell sandbox-container model. EC-4 (tmpfs unlinked) was retired. |
| `contracts/tfvars-inputs.md` | Mostly current | The variable contract is unchanged except for two fields: `foundry_base_url` is now derived as `${foundry_endpoint}/openai/v1`, and the `foundry_deployments` map's `api_version` field is no longer wired into NemoClaw's config. |

## Where the live architecture is documented

- [`docs/THREAT_MODEL.md`](../../docs/THREAT_MODEL.md) — §"Mediation
  channel" describes how OpenShell intercepts inference traffic on
  the host, where the credential persists, and which Principle II
  guarantees the deploy upholds.
- [`README.md`](../../README.md) — operator-facing summary of what
  the deploy provisions and the happy-path commands.
- `cloud-init/scripts/05-nemoclaw.sh` — the implementation of the
  install + onboard flow.
- `scripts/verify.sh` SC-004 — the Principle II tooth-check
  (re-implemented around OpenShell sandbox containers).

## Why preserve this directory

Two reasons:

1. **Audit trail.** A future security review can trace what was
   originally specified, what was implemented, and why the pivot
   happened. That history is more valuable than a clean rewrite that
   pretends v0.1 never existed.
2. **Spec-kit workflow.** This project uses
   [GitHub Spec-Kit](https://github.com/github/spec-kit) for design
   documentation. The spec-kit artifacts (spec → plan → research →
   contracts → tasks) demonstrate the methodology even when the
   implementation diverges. v2 will start a fresh
   `specs/002-...` directory with a v0.2 plan informed by what we
   learned.

## What's planned for v0.2

A new feature directory `specs/002-...` will:

- Capture the upstream-NemoClaw architecture as the foundation, not a
  pivot.
- Add a constitution amendment naming "intercept-on-host inference
  proxy" as an explicitly permitted Principle II mediation pattern
  (alongside the existing JIT-tmpfs example).
- Bake the Telegram / Discord / Slack channel onboarding into
  cloud-init (currently a manual `nemoclaw onboard` step post-deploy).
- Provider-generalize the Terraform variable surface so the deploy
  isn't Azure-Foundry-specific (currently `foundry_endpoint` /
  `foundry_primary_deployment_key` lock the operator to Foundry).
- Replace `~/.nemoclaw/credentials.json` persistence with a
  per-session KV fetch wrapper, if upstream NemoClaw exposes a hook
  for it.
