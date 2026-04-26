# Bootstrap stage — Terraform state backend

Runs **once per Azure subscription** with **local state** to
provision the Azure Storage account that all subsequent
`terraform/root/` applies will use as their remote backend.

This is the documented exception to constitution Principle V's
"state MUST live in a remote backend" rule — it is the bootstrap
of the backend itself.

---

## What this stage creates

- One resource group (`rg-nemoclaw`).
- One storage account (`tfstate<4-char-suffix>`) with:
  - `public_network_access_enabled = true` but firewalled to a
    single operator-supplied `/32` IP via `network_rules.ip_rules`.
  - `shared_access_key_enabled = false` (Azure AD auth only).
  - `default_to_oauth_authentication = true`.
  - `min_tls_version = "TLS1_2"`.
  - blob versioning + 7-day soft-delete on blobs and containers.
- One blob container (`tfstate`) for the root-stage state file.
- One `Storage Blob Data Contributor` role assignment, scoped to
  the storage account, granted to whoever ran `terraform apply`.

All resources carry the four mandatory constitution tags
(`project`, `owner`, `cost-center`, `managed-by`).

### Why public_network_access_enabled = true here

The constitution requires `public_network_access_enabled = false`
"where Private Endpoint or service endpoint coverage exists." For
the bootstrap stage, neither exists at v1 — there is no VNet yet
(the root stage creates it), and a Private Endpoint would need its
own private DNS zone plus a bridge for the operator's laptop to
reach (extra infra, ~$7+/mo, not justified for personal scope).

The compensating defense-in-depth at the data plane:

1. **IP allowlist** (`network_rules.ip_rules`) — only the operator's
   `/32` is admitted. Set via `var.operator_ip_cidr`.
2. **AAD-only auth** (`shared_access_key_enabled = false` +
   `default_to_oauth_authentication = true`) — no static keys
   exist; every request must carry a fresh AAD bearer token.
3. **Data-plane RBAC** (`Storage Blob Data Contributor`) scoped
   to this storage account only — Subscription Owner is *not*
   sufficient by itself.
4. **TLS 1.2 floor** — no downgrade.

A request must clear all four to read or write state.

---

## Usage

### First run

```bash
cd terraform/bootstrap

# Copy the example tfvars and fill in real values.
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars

terraform init       # local state, no backend config needed
terraform plan        -var-file=terraform.tfvars
terraform apply       -var-file=terraform.tfvars

# Capture the outputs — you will need them for terraform/root/.
terraform output -raw backend_config_block
```

The `backend_config_block` output prints a copy/pasteable
`terraform init -backend-config=...` invocation for the next stage.

### Subsequent root-stage applies

Bootstrap stays untouched. Every change goes through `terraform/root/`,
which reads its state from the storage account this stage created.

If `terraform/bootstrap/` ever needs an apply (e.g. to bump the
provider version or add a new tag), do it here with the same local
state file.

---

## Local state — back it up

The local `terraform.tfstate` in this directory is **gitignored** but
is also the only record of which storage account / RG holds your
remote state. Lose it and you have to import (see "Recovery" below).

Recommended: copy `terraform.tfstate` to a personal password manager
or a separate backed-up location after each apply. It contains no
secrets — just resource IDs.

---

## Recovery — local state file lost

If `terraform.tfstate` is gone but the Azure resources still exist,
recover by either:

### Option A — refresh-only (simpler)

```bash
terraform init  # creates a fresh local state
terraform refresh -refresh-only -var-file=terraform.tfvars
```

This rediscovers the existing resources and rebuilds local state from
their current Azure state.

### Option B — explicit import

```bash
terraform init

terraform import \
  -var-file=terraform.tfvars \
  azurerm_resource_group.state \
  /subscriptions/<sub-id>/resourceGroups/rg-nemoclaw

terraform import \
  -var-file=terraform.tfvars \
  azurerm_storage_account.state \
  /subscriptions/<sub-id>/resourceGroups/rg-nemoclaw/providers/Microsoft.Storage/storageAccounts/<storage-account-name>

terraform import \
  -var-file=terraform.tfvars \
  azurerm_storage_container.state \
  https://<storage-account-name>.blob.core.windows.net/tfstate

terraform import \
  -var-file=terraform.tfvars \
  random_string.suffix \
  <the-existing-4-char-suffix>
```

The `random_string` import is necessary; without it, the next plan
will want to recreate the resource and rename the storage account
(which would destroy the state container, taking the root state
with it).

---

## When your IP changes — recovery

The `operator_ip_cidr` var pins the data-plane firewall to your
laptop's current egress IP. When that IP changes (different
network, new ISP, mobile hotspot, VPN flip):

1. **If you can still reach the data plane (you haven't tried
   yet)**: edit `terraform.tfvars`, update `operator_ip_cidr` to
   the new IP (`curl -s https://api.ipify.org` to find it), run
   `terraform apply` — the network rule updates in place, you're
   back in.

2. **If you're already locked out** (apply or init returns 403):
   the data plane is unreachable from your IP, but the *control
   plane* (ARM) still works. Two recovery paths:

   ```bash
   # Option A — add the new IP via az CLI (control plane).
   az storage account network-rule add \
     --resource-group rg-nemoclaw \
     --account-name <tfstate-account-name> \
     --ip-address "$(curl -s https://api.ipify.org)"

   # Then update terraform.tfvars and run apply to re-sync.
   ```

   ```text
   # Option B — Azure portal: Storage account → Networking →
   # Firewalls and virtual networks → "Add your client IP address"
   # → Save. Then update terraform.tfvars to match.
   ```

Tailscale does **not** help here: the storage account's blob
endpoint is on the public internet, not on your tailnet, so your
laptop's request egresses through your normal WAN regardless of
whether Tailscale is up. Routing through Tailscale would require
either the deployed VM as a subnet router *plus* a stable Azure
egress (NAT Gateway, hourly-billed) or a Private Endpoint inside
the deploy's VNet (also adds infra), neither of which is available
during bootstrap.

---

## Tearing down

`terraform destroy` here removes the state backend. **Do this only
after `terraform/root/`'s `destroy` has completed**, otherwise the
root state file is orphaned in a deleted container.

---

## Why a separate stage?

A single Terraform configuration cannot create the storage account
holding its own state (chicken-and-egg). Two-stage is the canonical
solution; the alternative — running `terraform init` against a
storage account the operator hand-creates in the portal — violates
constitution Principle V (no portal clicks).
