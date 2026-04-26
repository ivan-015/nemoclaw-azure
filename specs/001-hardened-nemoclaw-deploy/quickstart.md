# Quickstart: Hardened NemoClaw Azure Deployment (v1)

**Plan**: [plan.md](./plan.md)
**Date**: 2026-04-25

End-to-end operator setup, fresh-clone to working NemoClaw. Designed
to be ≤ 30 minutes wall-clock excluding one-time Azure / Tailscale /
Foundry account procurement (spec SC-001).

This is the document the README will link to. It is intentionally
short and does not duplicate the threat model or the contracts.

---

## 0. One-time prerequisites

You need accounts and tools before the first apply. None of these
involve this repo.

### 0.1 Azure

- [ ] A **dedicated personal Azure subscription**, separate from any
  work or shared subscription. Note its GUID.
- [ ] You have Owner or equivalent rights on it (`az role assignment
  list --assignee $(az ad signed-in-user show --query id -o tsv)
  --scope /subscriptions/<sub-id>`).
- [ ] `Microsoft.KeyVault` and `Microsoft.Compute` resource providers
  registered (`az provider register --namespace Microsoft.KeyVault &&
  az provider register --namespace Microsoft.Compute`).
- [ ] Quota for `Standard_B4als_v2` in `centralus`
  (`az vm list-usage --location centralus --query "[?contains(name.value,
  'BAlsv2')]"` — confirm `currentValue < limit`).

### 0.2 Tailscale

- [ ] A Tailscale tailnet (free tier is fine).
- [ ] An **auth key** generated with: reusable=false, ephemeral=true,
  pre-approved=true, expiry=24h, tag=`tag:nemoclaw`. Note the value
  — you will store it in Key Vault in step 2.
- [ ] An ACL entry that scopes the `tag:nemoclaw` device so only
  your devices can reach it. (See `docs/TAILSCALE.md`.)

### 0.3 Azure AI Foundry

- [ ] Your existing Foundry instance's endpoint URL
  (e.g. `https://my-foundry.openai.azure.com`).
- [ ] A **separate API key** for this deployment, NOT the production
  key. Create one in the Foundry portal under "Keys and Endpoint".
- [ ] One or more model deployment names you want to expose
  (e.g., `gpt-4o`).

### 0.4 Local toolchain

```bash
# macOS
brew install azure-cli terraform tailscale gh
```

```bash
# Verify versions
az --version          # >= 2.50
terraform version     # >= 1.6
tailscale version     # latest
gh --version          # any modern
```

### 0.5 Authenticate

```bash
az login
az account set --subscription "<your-personal-sub-guid>"

tailscale login
gh auth login            # only if you'll be cloning from GitHub
```

---

## 1. Clone

```bash
gh repo clone <owner>/nemoclaw-azure
cd nemoclaw-azure
```

(Or use `git clone` directly if you already have the URL.)

---

## 2. Bootstrap the Terraform state backend (run once per subscription)

This stage creates the storage account that holds Terraform state for
every subsequent apply. It uses **local** state for itself
(documented chicken-and-egg). You run it exactly once.

```bash
cd terraform/bootstrap

# Customize the example
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
# Set:
#   subscription_id = "<your-personal-sub-guid>"
#   location        = "centralus"
#   owner           = "<you@example.com>"

terraform init
terraform apply

# Note the outputs — you'll need them in step 4
terraform output
# storage_account_name = "..."
# resource_group_name  = "..."
# container_name       = "..."

cd ../..
```

The local `bootstrap/terraform.tfstate` is gitignored — keep a backup
somewhere safe (password manager, encrypted volume). Recovery
instructions are in `terraform/bootstrap/README.md`.

---

## 3. Pre-stage secrets in Key Vault

The Key Vault doesn't exist yet (it's created by the main apply), but
the secrets need to be populated *between* the apply (which creates
the empty vault) and the cloud-init run (which reads them).

You'll do this in two passes — *most* of the apply runs first, the
operator pauses to seed secrets, then the apply continues. This is
encoded as a `null_resource` checkpoint in the module. The operator-
facing flow:

```bash
cd terraform/root

cp examples/personal.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
# Fill in subscription_id, owner, foundry_endpoint, foundry_deployments,
# nemoclaw_version. Leave everything else at defaults.

# Initial init points at the remote backend created in step 2
terraform init \
  -backend-config="storage_account_name=<from step 2>" \
  -backend-config="container_name=<from step 2>" \
  -backend-config="resource_group_name=<from step 2>" \
  -backend-config="key=root.tfstate"

# First-stage apply — creates everything except the VM
terraform apply -target=module.keyvault -target=module.identity -target=module.network
```

Now the Key Vault exists; populate its secrets:

```bash
KV_NAME=$(terraform output -raw key_vault_name)

# Foundry API key
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name foundry-api-key \
  --value "<your-foundry-api-key>"

# Tailscale auth key (one-time use)
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name tailscale-auth-key \
  --value "<your-tailscale-auth-key>"
```

---

## 4. Final apply

Now run the unrestricted apply — this creates the VM, runs cloud-init,
brings up the broker and NemoClaw, and registers the VM on your
tailnet.

```bash
terraform apply
```

Expected duration: 8–12 minutes. The slow steps are:

- VM provisioning (~3 min)
- Cloud-init (~5–7 min — installs Tailscale, Docker, Node, broker,
  NemoClaw)

If `terraform apply` exits 0, the deployment is up.

---

## 5. Verify

Run the verification script (see `contracts/verification-checks.md`
for what each check does):

```bash
./scripts/verify.sh
```

It runs all 9 success-criterion checks plus the User Story 1
acceptance scenarios. **Every check must pass before declaring the
deployment good.** The Principle II tooth-check (SC-004) is the most
load-bearing — if it fails, you have a security regression to chase
before using the deployment.

---

## 6. Use NemoClaw

```bash
# From your laptop, on the tailnet:
VM=$(terraform output -raw vm_tailnet_hostname)

tailscale ssh $VM
# you're now on the VM
nemoclaw                      # whatever your version's CLI is
```

When NemoClaw's systemd unit starts, the `ExecStartPre` script fetches
the Foundry API key from Key Vault (managed identity), writes it to a
tmpfs file at `/run/nemoclaw/env`, NemoClaw's host process consumes
it via systemd `EnvironmentFile=`, and the file is unlinked. NemoClaw's
own architecture isolates the sandboxed agent from this env var. You
won't see the secret anywhere in your shell.

---

## 7. Daily life

### Starting after auto-shutdown

The VM auto-shuts-down at 21:00 America/Los_Angeles. To use it again:

```bash
RG=$(terraform output -raw resource_group_name)
VM_NAME=$(terraform output -raw vm_name)
az vm start -g "$RG" -n "$VM_NAME"
# Wait ~3 minutes, then:
tailscale ping $(terraform output -raw vm_tailnet_hostname)
```

### Rotating the Foundry key

```bash
KV=$(terraform output -raw key_vault_name)
az keyvault secret set --vault-name "$KV" --name foundry-api-key --value "<new-key>"
# Restart NemoClaw to pick up the new value (the credential handoff
# script fetches fresh from KV at every service start):
tailscale ssh $(terraform output -raw vm_tailnet_hostname) -- sudo systemctl restart nemoclaw
```

### Upgrading NemoClaw

```bash
# Edit terraform.tfvars
$EDITOR terraform.tfvars
# Bump nemoclaw_version to the new tag

terraform plan      # confirm only the cloud-init / VM is changing
terraform apply     # this REPLACES the VM (research R8)
```

The VM is replaced because in-place NemoClaw upgrades aren't
reproducible. Plan for ~10 minutes of downtime.

### Tearing down

```bash
terraform destroy
# Then in the Tailscale admin console, manually remove the
# tag:nemoclaw node (research R5).
```

If you plan to re-deploy, run:

```bash
terraform taint random_string.deploy_suffix
```

…before the next `apply` so the new Key Vault gets a fresh name and
isn't blocked by the soft-deleted predecessor.

---

## 8. Troubleshooting

### "I can't reach the VM via Tailscale"

```bash
# Is the VM running?
az vm get-instance-view -g <rg> -n <vm> --query 'instanceView.statuses[*].code'

# Is Tailscale healthy on the VM? (uses the no-network debug path)
az vm run-command invoke -g <rg> -n <vm> \
  --command-id RunShellScript \
  --scripts "tailscale status; systemctl status tailscaled"
```

### "Cloud-init failed during the apply"

```bash
# Read cloud-init logs without SSH
az vm run-command invoke -g <rg> -n <vm> \
  --command-id RunShellScript \
  --scripts "cat /var/log/cloud-init-output.log; cat /var/log/cloud-init.log"

# If the VM is fully borked, attach the serial console:
az vm boot-diagnostics get-boot-log -g <rg> -n <vm>
# Or in the portal: VM → Help → Serial console
```

### "NemoClaw won't start (credential handoff failure)"

```bash
tailscale ssh <vm> -- "
  systemctl status nemoclaw
  journalctl -u nemoclaw --since '5 minutes ago'
"
```

Common causes:
- **MI not assigned**: `az login --identity` fails. Check
  `az vm identity show -g <rg> -n <vm>`.
- **MI lacks RBAC**: KV returns 403. Check the `Key Vault Secrets User`
  assignment for the MI on the KV resource scope.
- **KV unreachable**: KV network ACL doesn't allow the `vm` subnet.
  Check `az keyvault show -n <kv> --query 'properties.networkAcls'`.
- **Foundry secret missing or wrong name**: `az keyvault secret list -n <kv>`.

### "Cost is higher than expected"

```bash
# What's actually running?
az resource list -g <rg> --query "[?type!='Microsoft.Network/networkWatchers'].[type,name]" -o table

# Is auto-shutdown firing?
az monitor activity-log list -g <rg> --max-events 20 \
  --query "[?operationName.value=='Microsoft.Compute/virtualMachines/deallocate/action'].{when:eventTimestamp,who:caller}"
```

---

## What's next (v2 backlog)

After v1 is stable, candidates for v2 (in spec §"Out of Scope"):

- Logic-App auto-start so the VM wakes at 08:00 PT.
- Tailscale auth-key auto-rotation.
- Customer-managed encryption keys.
- Packer image bake (replaces cloud-init).
- Monitoring + alerting on unexpected downtime.
