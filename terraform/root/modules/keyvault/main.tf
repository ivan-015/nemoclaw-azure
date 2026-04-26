# Key Vault — single source of truth for the deploy's true secrets.
#
# Security posture (constitution Security Constraints + Principle III):
#   - RBAC mode (no access policies)
#   - public_network_access_enabled = false
#   - purge_protection_enabled       = true
#   - soft_delete_retention_days     = 7 (minimum; research R7 suffix
#     trick covers the destroy/redeploy case without waiting it out)
#   - network_acls: Deny default; AzureServices bypass for diagnostic
#     pipelines; allow only the deploy's vm subnet (R13 service-endpoint
#     route) plus the operator's /32 (so `az keyvault secret set` works
#     from their laptop between staged applies).
#   - Diagnostic settings (AuditEvent + AllMetrics) → Log Analytics
#     (FR-010 / SC-008 — every credential-handoff KV read is recorded
#     with identity + timestamp).
#   - VM MI has Get/List on secrets only (Key Vault Secrets User).
#     Operator has Set/Delete on secrets (Key Vault Secrets Officer)
#     for between-applies seeding. Both scoped to *this KV only*.

resource "azurerm_key_vault" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  sku_name = "standard"

  rbac_authorization_enabled = true

  # Subtle but important: `public_network_access_enabled = false`
  # disables the public endpoint ENTIRELY, ignoring network_acls.
  # Even an allowlisted /32 + an allowed VNet are rejected — only
  # Private Link gets through. Since v1 doesn't use Private Link
  # (research R13 — service endpoint instead), we need the public
  # endpoint enabled, then constrain it via network_acls.
  # Effective access is identical: default_action=Deny + bypass=
  # AzureServices + an explicit operator-IP allowlist + the vm
  # subnet's Microsoft.KeyVault service endpoint. Anything not in
  # those three categories is rejected at the firewall.
  public_network_access_enabled = true

  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days

  enabled_for_disk_encryption     = false
  enabled_for_deployment          = false
  enabled_for_template_deployment = false

  network_acls {
    default_action = "Deny"

    # AzureServices bypass keeps diagnostic settings flowing to Log
    # Analytics — that channel is constitution-required and Microsoft-
    # to-Microsoft, not internet-exposed.
    bypass = "AzureServices"

    # Subnet allowed via the Microsoft.KeyVault service endpoint
    # (research R13). The vm subnet has this endpoint enabled in the
    # network module.
    virtual_network_subnet_ids = [var.vm_subnet_id]

    # Operator's laptop IP for the staged-apply seeding step. Narrow
    # /32 — the variable validation rejects anything broader.
    ip_rules = [var.operator_ip_cidr]
  }

  tags = var.tags
}

# ─── RBAC ─────────────────────────────────────────────────────────

# VM managed identity → Key Vault Secrets User (Get/List only).
# Scope is THIS KV; not subscription, not RG. Principle III in code.
resource "azurerm_role_assignment" "vm_mi_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.vm_managed_identity_principal_id

  description = "VM MI fetches foundry-api-key (and Tailscale auth key at first boot). Read-only by RBAC."
}

# Operator → Key Vault Secrets Officer (Get/List/Set/Delete).
# Lets `az keyvault secret set` work between staged applies without a
# separate manual RBAC step. Still scoped to this single KV.
resource "azurerm_role_assignment" "operator_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.operator_principal_id

  description = "Operator seeds foundry-api-key + tailscale-auth-key between applies. Scope: this KV only."
}

# ─── Diagnostic settings → Log Analytics ──────────────────────────

resource "azurerm_monitor_diagnostic_setting" "kv_audit" {
  name                       = "diag-keyvault-audit"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ─── Placeholder secrets ──────────────────────────────────────────
#
# The operator overwrites these via `az keyvault secret set` after
# the staged apply creates the KV (quickstart §3). The placeholders
# exist so:
#   1. cloud-init's KV reads target a known secret name (Get fails
#      gracefully if the operator forgot to overwrite).
#   2. RBAC permits the operator's overwrite (the role assignment
#      depends on the KV; with placeholders the secrets exist before
#      the operator runs `az keyvault secret set`, so the data-plane
#      `Set` succeeds first try).
#
# `lifecycle.ignore_changes = [value, version, expiration_date,
# not_before_date]` is critical: subsequent `terraform apply` calls
# MUST NOT revert the operator's seeded values back to placeholders.
# We also ignore tags so the operator can annotate via portal/CLI.

# Terraform-managed version is a PLACEHOLDER overwritten by the
# operator via `az keyvault secret set` per quickstart §3.
# Per-version expiry on the placeholder does not propagate to the
# operator's overwrite (KV expiry is per-version), so tfsec's
# azure-keyvault-ensure-secret-expiry rule is unaddressable from
# this side. Real key rotation is via the documented restart flow
# (quickstart §7); Tailscale's 24h ephemeral expiry covers the
# tailscale-auth-key (docs/TAILSCALE.md §5).
#tfsec:ignore:azure-keyvault-ensure-secret-expiry
resource "azurerm_key_vault_secret" "foundry_api_key" {
  name         = "foundry-api-key"
  key_vault_id = azurerm_key_vault.main.id
  value        = "PLACEHOLDER-OVERWRITE-WITH-AZ-KEYVAULT-SECRET-SET"
  content_type = "text/plain"

  tags = {
    purpose  = "inference-credential"
    rotation = "manual-v1"
  }

  depends_on = [
    azurerm_role_assignment.operator_secrets_officer,
  ]

  lifecycle {
    # `version` is computed by the provider (each az keyvault secret
    # set creates a new version), so it doesn't belong in
    # ignore_changes. The other attributes here ensure subsequent
    # applies don't revert the operator's seeded value, expiry, or
    # tags back to the placeholders.
    ignore_changes = [
      value,
      expiration_date,
      not_before_date,
      tags,
    ]
  }
}

# Same reasoning as foundry_api_key above; placeholder overwritten
# by operator. Tailscale-side 24h ephemeral expiry is the actual
# mitigation (docs/TAILSCALE.md §5).
#tfsec:ignore:azure-keyvault-ensure-secret-expiry
resource "azurerm_key_vault_secret" "tailscale_auth_key" {
  name         = "tailscale-auth-key"
  key_vault_id = azurerm_key_vault.main.id
  value        = "PLACEHOLDER-OVERWRITE-WITH-AZ-KEYVAULT-SECRET-SET"
  content_type = "text/plain"

  tags = {
    purpose     = "node-bootstrap"
    consumed-by = "cloud-init"
    rotation    = "ephemeral"
  }

  depends_on = [
    azurerm_role_assignment.operator_secrets_officer,
  ]

  lifecycle {
    # `version` is computed by the provider (each az keyvault secret
    # set creates a new version), so it doesn't belong in
    # ignore_changes. The other attributes here ensure subsequent
    # applies don't revert the operator's seeded value, expiry, or
    # tags back to the placeholders.
    ignore_changes = [
      value,
      expiration_date,
      not_before_date,
      tags,
    ]
  }
}
