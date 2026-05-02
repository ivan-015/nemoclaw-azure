# Auto-start runbook for the NemoClaw VM.
#
# Pairs with the auto-shutdown schedule in main.tf: shutdown
# deallocates nightly to keep cost in the $40-80 envelope, this
# module wakes the VM each morning so the operator doesn't have to
# `az vm start` and wait on Tailscale rejoin every day.
#
# Stack:
#   - Azure Automation Account (Basic SKU; first 500 job-min/month
#     free, our daily 1-min start job consumes ~30 min/month)
#   - System-assigned managed identity, granted "Virtual Machine
#     Contributor" only on the target VM scope (least privilege)
#   - PowerShell runbook calls Connect-AzAccount -Identity then
#     Start-AzVM -NoWait. Idempotent — Start-AzVM on an already-
#     running VM is a no-op.
#   - Daily schedule with operator-configured local time & IANA tz.
#
# Why Automation Account vs Logic App: the AzureRM provider has
# clean Terraform-native support for Automation runbooks; Logic App
# managed-identity-against-ARM requires hand-crafting the workflow
# JSON to set authentication={type:ManagedServiceIdentity}, which
# the provider doesn't expose as first-class fields.

resource "azurerm_automation_account" "main" {
  name                = "auto-nemoclaw-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Basic"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# Least-privilege role assignment scoped to the single VM. The
# Automation Account's MI cannot touch any other resource.
resource "azurerm_role_assignment" "vm_contributor" {
  scope                = var.vm_resource_id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

resource "azurerm_automation_runbook" "start_vm" {
  name                    = "Start-NemoClawVM"
  resource_group_name     = var.resource_group_name
  location                = var.location
  automation_account_name = azurerm_automation_account.main.name
  log_verbose             = true
  log_progress            = true
  description             = "Wakes the NemoClaw VM. Triggered daily by the auto-start schedule. Idempotent: Start-AzVM on a running VM is a no-op."
  runbook_type            = "PowerShell"

  content = <<-PWSH
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'Stop'
    Connect-AzAccount -Identity | Out-Null
    Set-AzContext -Subscription '${var.subscription_id}' | Out-Null

    Write-Output "Starting VM: ${var.vm_name} in RG ${var.vm_resource_group_name}"
    Start-AzVM -ResourceGroupName '${var.vm_resource_group_name}' -Name '${var.vm_name}' -NoWait
    Write-Output "Start-AzVM dispatched (NoWait). Tailscale rejoin takes ~30s after boot."
  PWSH

  tags = var.tags
}

resource "azurerm_automation_schedule" "daily_start" {
  name                    = "daily-start-${var.name_suffix}"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  description             = "Fires Start-NemoClawVM daily at ${var.auto_start_local_time} ${var.auto_start_tz}."

  frequency = "Day"
  interval  = 1
  # Note: azurerm_automation_schedule expects IANA timezones (e.g.
  # "America/Los_Angeles") — opposite of azurerm_dev_test_global_vm_
  # shutdown_schedule which wants Windows IDs ("Pacific Standard Time").
  timezone = var.auto_start_tz

  # First run = configured wall-clock time on the day after apply.
  # Azure requires start_time to be 5min-6days in the future AT
  # CREATE; once the schedule exists, recurrence handles future
  # fires (the timezone field above keeps them DST-correct).
  # ignore_changes on start_time prevents re-apply churn from
  # timestamp() returning fresh values on every plan.
  start_time = "${formatdate("YYYY-MM-DD", timeadd(timestamp(), "26h"))}T${var.auto_start_local_time}:00${var.tz_offset_hint}"

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "daily_start" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  schedule_name           = azurerm_automation_schedule.daily_start.name
  runbook_name            = azurerm_automation_runbook.start_vm.name
}
