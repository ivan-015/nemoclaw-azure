# Log Analytics workspace for centralised audit:
#   - Key Vault SecretGet events (FR-010, SC-008 — the load-bearing
#     audit trail for the credential handoff path).
#   - NSG flow logs via Traffic Analytics (constitution Security
#     Constraints).
#
# `PerGB2018` is the only modern SKU available for new workspaces;
# the retired SKUs ("Free", "Standard", "Premium") aren't accepted by
# the API since 2018.

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-nemoclaw-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_in_days

  # Disable cross-workspace data sharing — there's nothing to share at
  # v1 and a closed posture is the right default.
  internet_ingestion_enabled = true # AzureDiagnostics from KV/NSG flow logs ship via the public ingestion endpoint
  internet_query_enabled     = true # operator queries from `az monitor log-analytics query` over the public endpoint

  tags = var.tags
}
