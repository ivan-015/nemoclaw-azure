# Contract: Terraform Module Inputs

**Plan**: [../plan.md](../plan.md)
**Date**: 2026-04-25

The `terraform/root/` module is the operator's Terraform entry point.
This document is the source-of-truth for every input variable: name,
type, default, validation rules, sensitivity classification, and the
spec FR(s) it traces to.

## Variables

### `subscription_id`

- **Type**: `string`
- **Required**: yes (no default)
- **Sensitive**: no
- **Description**: The personal Azure subscription ID this deployment
  targets. Must be different from any production subscription.
- **Validation**: matches the Azure subscription GUID pattern
  `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
- **Traces to**: spec Assumption "Personal Azure subscription".

### `location`

- **Type**: `string`
- **Default**: `"centralus"`
- **Sensitive**: no
- **Description**: Azure region.
- **Validation**: must be one of a known-good list of Azure regions
  where the chosen `vm_sku` is consistently available
  (`eastus`, `eastus2`, `centralus`, `westus2`, `westus3`,
  `northeurope`, `westeurope`).
- **Traces to**: Assumption "Region default `centralus`"; constitution
  Cost & Operational Constraints (region default override).

### `vm_sku`

- **Type**: `string`
- **Default**: `"Standard_B4als_v2"`
- **Sensitive**: no
- **Description**: VM size. Must satisfy NemoClaw's verified upstream
  minimum (4 vCPU, 8 GB RAM).
- **Validation**: must be one of an allowlisted set of SKUs known to
  meet NemoClaw's requirements
  (`Standard_B4als_v2`, `Standard_B4as_v2`, `Standard_B4ms`,
  `Standard_D4as_v5`, `Standard_D4s_v5`). Rejecting anything outside
  the list keeps an operator from accidentally undersizing.
- **Traces to**: spec Assumption "VM SKU default";
  Plan Constitution Check / Complexity Tracking entry.

### `nemoclaw_version`

- **Type**: `string`
- **Required**: yes (no default)
- **Sensitive**: no
- **Description**: Upstream NemoClaw release tag (e.g.,
  `v0.3.1`). MUST NOT be `main` or `latest`.
- **Validation**: must match `^v\d+\.\d+\.\d+(-\w+)?$` (semver-shaped
  with optional pre-release suffix). Reject `main`, `latest`, `head`.
- **Traces to**: constitution Principle V; research R8.

### `foundry_endpoint`

- **Type**: `string`
- **Required**: yes (no default)
- **Sensitive**: no (per spec Q2 clarification — endpoint URL is not a
  secret).
- **Description**: The Azure AI Foundry endpoint URL NemoClaw will
  call.
- **Validation**: must start with `https://` and resolve as a valid
  URL via Terraform's `regex` function.
- **Traces to**: spec Q2 clarification, FR-013 amendment.

### `foundry_deployments`

- **Type**: `map(object({ model = string, api_version = string }))`
- **Required**: yes
- **Sensitive**: no
- **Description**: Map of deployment-name → model + API version. At
  least one entry is required; the operator's NemoClaw config picks
  one (or more) by name.
- **Validation**: `length(var.foundry_deployments) > 0`.
- **Example**:
  ```hcl
  foundry_deployments = {
    primary = {
      model       = "gpt-4o"
      api_version = "2024-11-20"
    }
  }
  ```
- **Traces to**: spec Q2 clarification.

### `tailscale_tag`

- **Type**: `string`
- **Default**: `"tag:nemoclaw"`
- **Sensitive**: no
- **Description**: Tailscale tag advertised by the VM. The operator's
  Tailscale ACL should reference this tag to scope which devices can
  reach the VM.
- **Validation**: matches `^tag:[a-z0-9-]+$`.
- **Traces to**: research R3, R5; spec FR-003.

### `auto_shutdown_enabled`

- **Type**: `bool`
- **Default**: `true`
- **Sensitive**: no
- **Description**: Whether to provision the nightly shutdown schedule.
- **Traces to**: spec FR-021, SC-005.

### `auto_shutdown_local_time`

- **Type**: `string`
- **Default**: `"21:00"`
- **Sensitive**: no
- **Description**: Local time at which the VM deallocates daily.
- **Validation**: `^([01]\d|2[0-3]):[0-5]\d$`.
- **Traces to**: spec FR-021.

### `auto_shutdown_tz`

- **Type**: `string`
- **Default**: `"America/Los_Angeles"`
- **Sensitive**: no
- **Description**: Timezone for the shutdown schedule. IANA tz
  database name.
- **Validation**: must be one of an allowlisted IANA name set
  (validation against the Azure-supported timezone list, sourced from
  Microsoft documentation in the module's README).
- **Traces to**: spec FR-021.

### `owner`

- **Type**: `string`
- **Required**: yes (no default)
- **Sensitive**: no
- **Description**: Email address or GitHub handle responsible for
  this deployment. Becomes the `owner` tag on every resource.
- **Validation**: matches `^[\w.+-]+@[\w-]+\.[\w.-]+$` OR
  `^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$` (GitHub username).
- **Traces to**: constitution Cost & Operational Constraints (tag).

### `cost_center`

- **Type**: `string`
- **Default**: `"personal"`
- **Sensitive**: no
- **Description**: Cost-center tag value.
- **Traces to**: constitution Cost & Operational Constraints.

### `tags`

- **Type**: `map(string)`
- **Default**: `{}`
- **Sensitive**: no
- **Description**: Extra tags merged with the four mandatory tags.
  Operator-supplied keys MUST NOT override `project`, `owner`,
  `cost-center`, or `managed-by` (`locals.tf` enforces this with
  `merge(var.tags, local.mandatory_tags)`).
- **Traces to**: constitution Cost & Operational Constraints.

## Validation rule philosophy

- **Reject insecure inputs at plan time** (Principle V) rather than
  surfacing them after apply. Every variable that affects security
  posture has a `validation` block.
- **Allowlist beats denylist**. `vm_sku` and `location` use
  allowlists because the cost of accidentally provisioning a too-small
  SKU or a wrong-region resource is higher than the cost of forcing
  the operator to add to the list when they have a real reason to.
- **No secrets in tfvars, ever.** The Foundry API key and Tailscale
  auth key are provisioned via `az keyvault secret set` outside
  Terraform; the variables here only point at the *names* and
  *endpoints*, not values.

## Examples shipped with the module

### `examples/personal.tfvars.example`

```hcl
subscription_id = "<your-personal-sub-guid>"
location        = "centralus"
vm_sku          = "Standard_B4als_v2"

nemoclaw_version = "<pin-an-actual-tag-here>"

foundry_endpoint = "https://<your-foundry-name>.openai.azure.com"
foundry_deployments = {
  primary = {
    model       = "gpt-4o"
    api_version = "2024-11-20"
  }
}

owner = "<you@example.com>"
```

### `examples/dev.tfvars.example`

Same as above plus:

```hcl
auto_shutdown_enabled = false
```
