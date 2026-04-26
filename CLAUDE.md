<!-- SPECKIT START -->
Active feature: **001-hardened-nemoclaw-deploy** (v1 hardened deploy).
Source of truth for all planning decisions:
- Spec: `specs/001-hardened-nemoclaw-deploy/spec.md`
- Plan: `specs/001-hardened-nemoclaw-deploy/plan.md`
- Research: `specs/001-hardened-nemoclaw-deploy/research.md`
- Data model: `specs/001-hardened-nemoclaw-deploy/data-model.md`
- Contracts: `specs/001-hardened-nemoclaw-deploy/contracts/`
- Quickstart: `specs/001-hardened-nemoclaw-deploy/quickstart.md`
- Constitution (governing): `.specify/memory/constitution.md` (v1.0.0)

When working on this branch, prefer the spec/plan/contracts as source of
truth over `docs/IMPLEMENTATION_PLAN.md` (the latter is the local-only
narrative reference). For code-level decisions (Terraform module shape,
broker IPC, Key Vault layout), read `contracts/` first.
<!-- SPECKIT END -->
