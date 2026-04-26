# Contract: Key Vault Secret Layout

**Plan**: [../plan.md](../plan.md)
**Date**: 2026-04-25

The Key Vault holds **only true secrets**. Per spec Q2: endpoint URLs,
deployment names, and API versions live in Terraform variables, not
here.

## Naming convention

- Secret names use lowercase letters, digits, and hyphens (Azure Key
  Vault constraint: `^[0-9a-zA-Z-]{1,127}$`; we restrict further for
  human readability).
- Names are **stable** across re-deploys — operators expect the same
  names every time. The Key Vault *name* is suffix-uniqueified per
  research R7; the secret names inside it are not.

## v1 secrets

### `foundry-api-key`

- **Type**: text (Azure AI Foundry API key, written verbatim — no
  base64 wrapper).
- **Set by**: operator, after `terraform apply`, via
  `az keyvault secret set --vault-name "<name>" --name foundry-api-key
  --value "<key>"`.
- **Read by**: the credential handoff `ExecStartPre` script
  (`/usr/local/bin/nemoclaw-credential-handoff`) at NemoClaw service
  start, using the VM's user-assigned managed identity.
- **Lifecycle**: long-lived; rotation = `az keyvault secret set` with
  the same name (KV creates a new version), then `systemctl restart
  nemoclaw` to pick up the new value.
- **Tags**:
  - `purpose = "inference-credential"`
  - `rotation = "manual-v1"`
- **Expiry**: not set at v1 (manual rotation discipline).
- **Access path**: only the credential handoff script reads it.
  NemoClaw's host process never accesses KV directly; it receives
  the key via systemd `EnvironmentFile=` from a tmpfs file the
  handoff script wrote.

### `tailscale-auth-key`

- **Type**: text (Tailscale ephemeral auth key,
  e.g. `tskey-auth-...`).
- **Set by**: operator, **before** `terraform apply`, via the same
  CLI as above.
- **Read by**: cloud-init only, exactly once, on first boot, via the
  VM's managed identity.
- **Lifecycle**: one-time use at cloud-init. The persisted KV value
  becomes useless after Tailscale's 24h ephemeral expiry. The
  cloud-init log lines containing the key are scrubbed in-memory
  before write. v1 does NOT explicitly purge the KV-side secret
  (relying on Tailscale's natural expiry); v2 may add a Terraform
  `null_resource` purge.
- **Tags**:
  - `purpose = "node-bootstrap"`
  - `consumed-by = "cloud-init"`
  - `rotation = "ephemeral"`
- **Expiry**: 24 hours from generation (Tailscale-side enforcement).
- **Access path**: only cloud-init reads it. NemoClaw's host process
  has no business reading this key and never does — the handoff
  script's KV access is scoped (by Azure RBAC) to
  `foundry-api-key` only.

## RBAC

The VM's managed identity is granted **`Key Vault Secrets User`** role
at the Key Vault resource scope (not subscription, not RG). This role
permits `Get` and `List` on secrets. No `Set`, no `Delete`. The
operator (a human) uses their own Azure AD identity to set/rotate
secrets — separation of concerns.

The Terraform `null_resource` that purges the Tailscale auth key
runs with the operator's local `az login` credentials, not the VM's
identity, for the same reason.

## Diagnostic logging

Per constitution Security Constraints, the Key Vault diagnostic
setting MUST stream:

- `AuditEvent` log category
- `AllMetrics`

…to the Log Analytics workspace, with retention ≥ 30 days.

The operator can audit "who fetched what when" with KQL like:

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| project TimeGenerated, identity_claim_appid_g, requestUri_s,
          ResultSignature, ResultDescription
```

This is the *Azure-side* audit; the broker's journald audit is the
*VM-side* audit. Both should be cross-referenced when investigating
anomalies.

## Forbidden contents

The Key Vault MUST NOT contain at v1:

- Foundry endpoint URL
- Foundry deployment name(s)
- Foundry API version
- Tailscale tag value
- Subscription IDs / tenant IDs / region names
- Any non-secret configuration

Putting non-secrets in KV would unnecessarily route them through the
broker, expanding the broker's audit surface for no security gain
(spec Q2 rationale).

## Future expansion (v2 hooks, NOT in v1)

- Per-secret rotation hook (Key Vault event grid → broker cache
  invalidation).
- Customer-managed encryption key for KV itself.
- Foundry endpoint and deployment-name relocation if NemoClaw's
  deployment surface scales beyond a single Foundry.
