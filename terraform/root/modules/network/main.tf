# Network surface for the deploy.
#
# Constitution Principle I (Security as Default):
#   - Zero custom inbound NSG rules. The default DenyAllInbound (priority
#     65500) is the only inbound rule that appears in `az network nsg
#     rule list`, satisfying spec FR-002 and verification check 2b.
#   - Outbound is fail-closed: explicit allows at priorities 100–230,
#     explicit DenyAllOutbound at priority 4096 (overriding Azure's
#     permissive default AllowInternetOutbound at 65001).
#
# Research R2: outbound allowlist by service tag where Microsoft
# publishes one (AAD, KeyVault, Storage, MCR, AzureFrontDoor.FirstParty,
# CognitiveServicesManagement); Internet on narrow ports for endpoints
# without a service tag (Tailscale control + DERP, Foundry FQDN,
# Ubuntu mirrors, NodeSource).
#
# Research R13: vm subnet exposes the Microsoft.KeyVault service
# endpoint so the keyvault module can reference it in network_acls
# (replaces a Private Endpoint at zero marginal cost for v1's
# single-consumer scale).

# ─── VNet + subnet ────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "vnet-nemoclaw"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.vm_subnet_address_prefix]

  # The Key Vault service endpoint (R13). Pairs with the keyvault
  # module's network_acls block restricting access to this subnet.
  service_endpoints = ["Microsoft.KeyVault"]
}

# ─── NSG ──────────────────────────────────────────────────────────

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-nemoclaw-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ─── Outbound allowlist (priority 100 → 230) ──────────────────────
#
# Each rule is the narrowest expression of one egress destination
# from research R2. Service tags are preferred over Internet because
# Microsoft maintains them as their IP ranges shift.

resource "azurerm_network_security_rule" "out_aad" {
  name                        = "AllowOutbound-AzureActiveDirectory-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "AzureActiveDirectory"
  description                 = "Managed identity token issuance (R2)."
}

resource "azurerm_network_security_rule" "out_keyvault" {
  name                        = "AllowOutbound-AzureKeyVault-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "AzureKeyVault.${var.location}"
  description                 = "Key Vault data plane (R2). Regional service tag — tightens the rule to the deploy's region."
}

resource "azurerm_network_security_rule" "out_storage" {
  name                        = "AllowOutbound-Storage-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Storage.${var.location}"
  description                 = "Azure Storage (state backend, image source for Marketplace, etc.) (R2)."
}

resource "azurerm_network_security_rule" "out_mcr" {
  name                        = "AllowOutbound-MicrosoftContainerRegistry-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "MicrosoftContainerRegistry"
  description                 = "Microsoft Container Registry (Docker image pulls for first-party Microsoft images) (R2)."
}

resource "azurerm_network_security_rule" "out_frontdoor" {
  name                        = "AllowOutbound-AzureFrontDoorFirstParty-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 140
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "AzureFrontDoor.FirstParty"
  description                 = "AFD CDN backing MCR + Azure CLI download paths (R2)."
}

resource "azurerm_network_security_rule" "out_cognitive_mgmt" {
  name                        = "AllowOutbound-CognitiveServicesManagement-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 150
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "CognitiveServicesManagement.${var.location}"
  description                 = "Azure AI Foundry control plane (R2). Foundry data-plane FQDN traffic falls through to AllowOutbound-Internet-443."
}

# ─── Internet allows on narrow ports (priority 200 → 240) ─────────
#
# NSGs do not support FQDN matching (Azure Firewall does, but it costs
# ~$900/mo base which would dwarf the project — see R2). For
# destinations that are not covered by a service tag (Tailscale
# control/DERP, Foundry data-plane FQDN, deb.nodesource.com,
# *.ubuntu.com), we restrict by port and protocol instead. This is
# narrower than the constitution-permitted "Internet" tag plus a `*`
# port — we never use `*` on a destination port for an Internet rule.

resource "azurerm_network_security_rule" "out_https_internet" {
  name                        = "AllowOutbound-Internet-443"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  description                 = "HTTPS for Tailscale control+DERP, Foundry FQDN, NodeSource, Ubuntu mirrors (R2). NSG can't FQDN-match; port-scoped."
}

resource "azurerm_network_security_rule" "out_http_internet" {
  name                        = "AllowOutbound-Internet-80"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 210
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  description                 = "Apt repository handshake + signature fetch (HTTP fallback for InRelease/Packages on Ubuntu + NodeSource mirrors)."
}

resource "azurerm_network_security_rule" "out_dns" {
  name                        = "AllowOutbound-Internet-DNS-53"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 220
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "53"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  description                 = "DNS resolution. Azure DNS at 168.63.129.16 plus public resolvers in case the VM is reconfigured to an external one."
}

resource "azurerm_network_security_rule" "out_tailscale_direct" {
  name                        = "AllowOutbound-Tailscale-Direct-UDP-41641"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 230
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "41641"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  description                 = "Tailscale direct WireGuard (R2). Falls back to DERP over 443/TCP via AllowOutbound-Internet-443 when UDP blocked."
}

resource "azurerm_network_security_rule" "out_ntp" {
  name                        = "AllowOutbound-NTP-UDP-123"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 240
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "123"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  description                 = "Time sync. AAD token issuance fails if VM clock drifts >5 min, so NTP is load-bearing for managed-identity auth."
}

# ─── Explicit deny-all-outbound at priority 4096 ──────────────────
#
# Azure's default AllowInternetOutbound (priority 65001) would otherwise
# permit any TCP/UDP destination on any port. This rule overrides it
# while leaving room (4096 < 65000) for any future custom allow rule
# without renumbering.

resource "azurerm_network_security_rule" "out_deny_all" {
  name                        = "DenyOutbound-All"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  priority                    = 4096
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  description                 = "Fail-closed catch-all (Principle I). Overrides Azure's default AllowInternetOutbound which would otherwise permit egress."
}

# ─── NSG flow logs ────────────────────────────────────────────────
#
# Constitution Security Constraints — NSG flow logs MUST flow to a
# Log Analytics workspace with retention >= 30 days. We use
# Network Watcher's flow log feature targeting a dedicated storage
# account, then enable Traffic Analytics so the workspace sees the
# enriched stream.

# Flow logs writer is a first-party Azure service. It currently
# requires shared keys on the storage account; AAD-only is not
# supported as of 2026-04. Documented exception to the constitution's
# "shared_access_key_enabled = false where Azure AD auth is feasible"
# clause — AAD is *not* feasible here.
resource "azurerm_storage_account" "flowlogs" {
  name                = "stnsgflow${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  public_network_access_enabled   = true # required by Network Watcher writer; tightened below
  shared_access_key_enabled       = true # NSG flow logs writer requires; documented exception
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  # Restrict data plane to Azure first-party services only.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices", "Logging", "Metrics"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# Network Watcher is auto-provisioned by Azure in NetworkWatcherRG
# per region. Use a data source rather than `azurerm_network_watcher`
# resource so a re-apply doesn't fight Azure's automatic creation.
# If this lookup fails, the operator runs once:
#   az network watcher configure --enabled true --locations <region>
data "azurerm_network_watcher" "main" {
  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "azurerm_network_watcher_flow_log" "vm" {
  name                 = "flowlog-nemoclaw-vm"
  network_watcher_name = data.azurerm_network_watcher.main.name
  resource_group_name  = data.azurerm_network_watcher.main.resource_group_name
  target_resource_id   = azurerm_network_security_group.vm.id
  storage_account_id   = azurerm_storage_account.flowlogs.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = 30
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = data.azurerm_log_analytics_workspace.lookup.workspace_id
    workspace_region      = var.location
    workspace_resource_id = var.log_analytics_workspace_id
    interval_in_minutes   = 10
  }

  tags = var.tags
}

# Traffic Analytics needs the workspace's internal GUID
# (`workspace_id`), not the Azure resource ID. We get the resource ID
# from the log-analytics module via var.log_analytics_workspace_id and
# look up the GUID here.
data "azurerm_log_analytics_workspace" "lookup" {
  name                = reverse(split("/", var.log_analytics_workspace_id))[0]
  resource_group_name = var.resource_group_name
}
