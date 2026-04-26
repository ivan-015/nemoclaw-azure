# tflint — Terraform linter configuration.
# Run via: `tflint --init && tflint -f compact` from the repo root.
# Phase 8 task T053 enforces zero findings before the v1 PR.

config {
  format = "compact"
  module = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  # 0.28.0 is the floor for azurerm provider 4.x support; 0.32.0 is
  # the current latest (verified 2026-04-25).
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
