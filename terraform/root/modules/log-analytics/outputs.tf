# log-analytics module — outputs.

output "id" {
  value       = azurerm_log_analytics_workspace.main.id
  description = "Workspace resource ID. Consumed by keyvault diagnostic settings and network flow log Traffic Analytics."
}

output "workspace_id" {
  value       = azurerm_log_analytics_workspace.main.workspace_id
  description = "Internal workspace GUID — needed by NSG flow log Traffic Analytics (separate from the resource ID)."
}

output "name" {
  value       = azurerm_log_analytics_workspace.main.name
  description = "Workspace name."
}
