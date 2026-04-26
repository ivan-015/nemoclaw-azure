# Bootstrap stage — Terraform state backend

Runs **once per Azure subscription** with **local state** to
provision the Azure Storage account that all subsequent
`terraform/root/` applies will use as their remote backend.

This is the documented exception to constitution Principle V's
"state MUST live in a remote backend" rule — it is the bootstrap
of the backend itself.

---

## What this stage creates

- One resource group (`rg-nemoclaw-tfstate`).
- One storage account (`tfstate<4-char-suffix>`) with:
  - `public_network_access_enabled = false`
  - `shared_access_key_enabled = false` (Azure AD auth only)
  - `min_tls_version = "TLS1_2"`
  - blob versioning + 7-day soft-delete on blobs and containers.
- One blob container (`tfstate`) for the root-stage state file.

All resources carry the four mandatory constitution tags
(`project`, `owner`, `cost-center`, `managed-by`).

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
  /subscriptions/<sub-id>/resourceGroups/rg-nemoclaw-tfstate

terraform import \
  -var-file=terraform.tfvars \
  azurerm_storage_account.state \
  /subscriptions/<sub-id>/resourceGroups/rg-nemoclaw-tfstate/providers/Microsoft.Storage/storageAccounts/<storage-account-name>

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
