# Security Policy

## Reporting a Vulnerability

This repository deploys infrastructure that touches identity, secrets,
and network surface — please report security issues **privately** rather
than through public GitHub issues.

**To report a vulnerability**, open a private security advisory:
<https://github.com/ivan-015/nemoclaw-azure/security/advisories/new>

Or email the maintainer directly. Allow up to 7 days for an initial
acknowledgement.

What to include:

- Affected commit / tag.
- Reproduction steps or proof-of-concept.
- Impact assessment (what an attacker could read, write, or move).
- Whether you've notified upstream NemoClaw / Azure / Tailscale (if
  the issue lives upstream rather than in this deploy's wrapping).

## Scope

In scope for this repository:

- The Terraform modules under `terraform/`.
- The cloud-init scripts under `cloud-init/`.
- The verification suite under `scripts/`.
- The credential-handling flow documented in
  [`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md).
- Misconfigurations or omissions that weaken the Tailscale-only
  ingress posture, the Key Vault network ACL, the managed-identity
  RBAC scope, or the operator-IP allowlist.

Out of scope (please report to the relevant upstream instead):

- Vulnerabilities in [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw)
  or its dependencies (OpenShell, OpenClaw).
- Vulnerabilities in [Tailscale](https://tailscale.com/security/),
  [Docker](https://www.docker.com/legal/security/), or the Azure
  platform.
- Vulnerabilities in third-party policy presets (`npm`, `pypi`, etc.)
  applied at sandbox build time.

## Threat Model

The full threat model — assets, attackers, mitigations, residual
risks, and the credential-handling path — is documented in
[`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md). Please reference
that document when reporting issues; it's the source of truth for
what guarantees the deploy claims to provide.

## Disclosure Window

Once an issue is acknowledged:

- Severity assessment within **7 days**.
- Fix or mitigation guidance within **30 days** for HIGH/CRITICAL,
  **90 days** for LOWER.
- Coordinated public disclosure after a fix lands, with credit to the
  reporter unless they prefer to remain anonymous.

This is a single-maintainer project — response times are best-effort.
