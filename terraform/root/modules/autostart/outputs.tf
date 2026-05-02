output "automation_account_id" {
  value       = azurerm_automation_account.main.id
  description = "Automation Account resource ID — useful for ad-hoc job inspection via `az automation`."
}

output "automation_account_name" {
  value       = azurerm_automation_account.main.name
  description = "Automation Account name."
}

output "runbook_name" {
  value       = azurerm_automation_runbook.start_vm.name
  description = "Runbook name. Trigger ad-hoc with: az automation runbook start --automation-account-name <acct> --resource-group <rg> --name <runbook>."
}

output "schedule_first_run_utc" {
  value       = azurerm_automation_schedule.daily_start.start_time
  description = "First scheduled run time in UTC. Subsequent fires are at the same wall-clock time in tz_windows daily."
}
