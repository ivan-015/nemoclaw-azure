# Contract: Credential Handoff

**Status**: ⚠️ **Superseded** by upstream NemoClaw's OpenShell-on-host
inference proxy. This document is preserved for the audit trail; do
not implement against it.

## Why this contract was retired

The original v0.1 design specified a just-in-time tmpfs credential
handoff: cloud-init renders a systemd unit with `ExecStartPre=` that
fetches the Foundry API key from Key Vault, writes it to a mode-0400
file under `/run/nemoclaw/`, the unit consumes it via
`EnvironmentFile=`, and `ExecStartPost=` unlinks the file. The intent
was to satisfy constitution Principle II's "JIT tmpfs file with
restrictive permissions deleted after use" example.

When the implementation pivoted to upstream's actual install path
(see `cloud-init/scripts/05-nemoclaw.sh` and the
`refactor: align with NemoClaw upstream` commit), it became clear
that:

1. NemoClaw is **not a daemon** — it's CLI-driven. There is no
   `nemoclaw.service`. Operator runs `nemoclaw <sandbox> connect` to
   enter the sandbox via Tailscale SSH; OpenShell + Docker + k3s run
   as their own services, but NemoClaw itself never registers a
   systemd unit.

2. The sandbox-isolation guarantee is enforced by **OpenShell's
   intercept-on-host design**, not by withholding the credential
   from a shared environ. Per upstream's
   `docs/inference/inference-options.md`: "Provider credentials
   stay on the host. The sandbox does not receive your API key.";
   "The agent inside the sandbox talks to `inference.local`. It
   never connects to a provider directly. OpenShell intercepts
   inference traffic on the host and forwards it to the provider
   you selected."

3. Therefore the JIT-tmpfs pattern was solving a problem that
   upstream had already solved at the network-namespace +
   filesystem-policy boundary. Implementing it on top of upstream
   would have been duplicative AND wouldn't have changed the actual
   security posture.

## Current credential flow

See `docs/THREAT_MODEL.md` §"Mediation channel: OpenShell intercepts
inference traffic on the host" for the in-effect description.

In short:

1. Cloud-init (root, with VM managed identity) fetches the Foundry
   API key from Key Vault via `az keyvault secret show`.
2. The key is piped via stdin (never argv, never persistent env)
   into a runner script that invokes upstream's
   `https://www.nvidia.com/nemoclaw.sh` non-interactively, with
   `NEMOCLAW_PROVIDER=custom`, `COMPATIBLE_API_KEY=<the key>`,
   `NEMOCLAW_ENDPOINT_URL=<Foundry /openai/v1 base>`.
3. The installer + `nemoclaw onboard` validate the credential and
   persist it under `~/.nemoclaw/credentials.json` (mode 0600,
   owned by the operator user).
4. OpenShell gateway loads the file, intercepts agent inference
   traffic at `inference.local`, forwards to Foundry with the key
   attached. The sandbox container never sees the key.

## Constitution Principle II compliance

The constitution Principle II's exact text permits "a local broker
on a Unix domain socket; a just-in-time tmpfs file with restrictive
permissions deleted after use" as **examples** of mediation channels,
not an exhaustive list. The OpenShell intercept-on-host design is a
distinct mediation pattern that satisfies the same threat-model goal:
the sandboxed agent's environ, cmdline, and filesystem view never
contain the secret value. Verified by `scripts/verify.sh` SC-004.

The next constitution amendment should explicitly add
"intercept-on-host inference proxy" to the named patterns.

## What replaces this contract

Operational reality is documented in:

- `docs/THREAT_MODEL.md` §"Mediation channel"
- `cloud-init/scripts/05-nemoclaw.sh` (the implementation)
- `scripts/verify.sh` SC-004 (the verification)
- Upstream NemoClaw's `docs/inference/inference-options.md`
