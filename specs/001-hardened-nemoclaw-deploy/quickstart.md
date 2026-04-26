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

The VM auto-shuts-down at 21:00 America/Los_Angeles by default
(configurable via `auto_shutdown_local_time` / `auto_shutdown_tz`;
disable for active iteration days with the `dev.tfvars.example`
profile). To wake it again, run the printable `az vm start ...`
emitted as a Terraform output:

```bash
$(terraform output -raw start_command)
# Wait ~3 minutes, then:
tailscale ping $(terraform output -raw vm_tailnet_hostname)
```

The credential handoff fires on every service start, so post-
deallocation NemoClaw re-fetches the Foundry API key from Key Vault
without operator intervention. If Tailscale doesn't come back
within ~3 min, jump to §8 troubleshooting.

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

The teardown is three steps: Terraform, Tailscale, then (if you'll
redeploy) suffix taint. Each step is idempotent.

```bash
# 1. Tear down all Azure resources in this RG.
terraform destroy
```

The Key Vault enters its 7-day soft-delete retention period
(constitution Principle II requires `purge_protection_enabled`, which
forbids immediate hard-delete). The auto-shutdown schedule, VM, NIC,
NSG, network watcher flow logs, KV diagnostic settings, and managed
identity all hard-delete.

```bash
# 2. Manually remove the Tailscale node from the tailnet.
#    (No null_resource purge in v1 — see docs/TAILSCALE.md §4.)
```

Visit <https://login.tailscale.com/admin/machines>, find the node
with hostname `nemoclaw-<suffix>`, click "Remove". Idempotent — if
the ephemeral 24h expiry already auto-removed the node, the button
is a no-op.

The Tailscale auth key persists in the (soft-deleted) Key Vault
until the soft-delete retention expires OR the next apply
overwrites it. Tailscale's own 24h ephemeral-key expiry (set when
you generated the key — see `docs/TAILSCALE.md` §1) makes that
persisted KV value unusable as a credential after 24 hours; this is
the v1 mitigation for the residual KV-side copy. **No
`null_resource` purge runs at v1** — that's a v2 candidate
documented in `docs/TAILSCALE.md` §5.

```bash
# 3. (Optional, only if you'll redeploy.) Force a fresh suffix so
#    the new KV name doesn't collide with the soft-deleted one.
terraform taint random_string.deploy_suffix
terraform apply
```

The taint regenerates `random_string.deploy_suffix.result`, which
flows through `local.suffix` into every globally-unique resource
name (`kv_name`, `mi_name`, `resource_group_name`, the flow-logs
storage account, the VM name). The new KV gets a different name
and bypasses the 7-day soft-delete hold on the predecessor.

Without the taint, a redeploy within the soft-delete window will
fail at the KV creation step with "The vault name '<old-name>' is
currently in a soft-deleted state and cannot be reused for 6 days."
The taint is the documented escape hatch (research R7 / spec
FR-026); waiting out the soft-delete window also works but is
slower.

---

## 8. Troubleshooting (no-network debug walkthrough)

When something on the VM is broken, every diagnostic path below
uses **only the Azure control plane** — no inbound NSG rule, no
public IP, no Tailscale dependency. Three tiers, increasing in
severity:

| Tier | Path | When to use |
|---|---|---|
| 1 | `az vm run-command invoke` | VM running, Linux booted, only userland is broken |
| 2 | `az vm boot-diagnostics get-boot-log` | VM running but kernel/cloud-init noise needs reading |
| 3 | Azure portal → VM → "Serial console" | VM kernel broken or cloud-init hung; need an interactive console |

Set the variables once:

```bash
RG=$(terraform output -raw resource_group_name)
VM=$(terraform output -raw vm_name)
```

### "I can't reach the VM via Tailscale"

```bash
# Is the VM even running? Look for PowerState/running.
az vm get-instance-view -g "$RG" -n "$VM" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" -o tsv

# Is Tailscale healthy on the VM?
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "tailscale status; systemctl status tailscaled --no-pager"

# Restart Tailscale if the daemon is unhealthy.
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "systemctl restart tailscaled && sleep 3 && tailscale status"
```

If Tailscale's coordination plane itself is down, the daemon won't
recover — see `docs/TAILSCALE.md` §8 ("When Tailscale itself is
broken") for the broader recovery sequence.

### "Cloud-init failed during the apply"

Read the logs without ever opening a port. Cloud-init writes two
files; both are useful:

```bash
# Combined stdout/stderr from runcmd: scripts (most diagnostic).
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "cat /var/log/cloud-init-output.log"

# The structured cloud-init log itself.
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "tail -n 300 /var/log/cloud-init.log"
```

If cloud-init hung early enough that even Run Command isn't
available (rare — Run Command runs via the Azure VM agent, which is
up before cloud-init's user-space stage), fall back to the boot log:

```bash
az vm boot-diagnostics get-boot-log -g "$RG" -n "$VM"
```

…or attach the serial console interactively in the portal:
**VM blade → Help → Serial console**. The console shows the kernel
ring buffer + getty prompt; with a working `cloud-init` user
account you can log in and inspect the half-configured system.

### "NemoClaw won't start (credential handoff failure)"

```bash
# Tailscale path (preferred — interactive shell):
tailscale ssh "$(terraform output -raw vm_tailnet_hostname)" -- "
  systemctl status nemoclaw --no-pager
  journalctl -u nemoclaw --since '5 minutes ago' --no-pager
"

# No-Tailscale path (Run Command):
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "systemctl status nemoclaw --no-pager; journalctl -u nemoclaw -n 200 --no-pager"
```

Common causes (in roughly observed-frequency order):

- **`foundry-api-key` still the Terraform PLACEHOLDER**: the
  credential-handoff script rejects it. Run
  `az keyvault secret set --vault-name <kv> --name foundry-api-key --value <real-key>`
  then `systemctl restart nemoclaw` (via Run Command if Tailscale is
  also down).
- **MI not assigned**: `az login --identity` fails. Check
  `az vm identity show -g "$RG" -n "$VM"`.
- **MI lacks RBAC**: KV returns 403. Check the `Key Vault Secrets User`
  assignment on the KV resource scope.
- **KV unreachable**: KV network ACL doesn't allow the `vm` subnet.
  Check `az keyvault show -n <kv> --query 'properties.networkAcls'`.
- **Foundry secret missing or wrong name**:
  `az keyvault secret list --vault-name <kv> --query "[].name" -o tsv`.

### "I need a shell on the VM but Tailscale is down"

Run Command runs as root and accepts any shell snippet — it's the
no-network equivalent of an SSH session for one-shot commands:

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "<your shell snippet>"
```

For a proper interactive shell, attach the serial console
(portal → VM → Help → Serial console). It logs in as the cloud-init
admin user (`azureuser` by default, but in this deploy that account
has no password — you'll need to set one via Run Command first if
serial console interactivity matters):

```bash
# One-time: set a password on azureuser so serial console accepts a login
# (not needed for Run Command itself).
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "echo 'azureuser:<temporary-strong-password>' | chpasswd"
```

Don't leave that password set after the debug session — clear it
with `passwd -d azureuser` when done.

### "Cost is higher than expected"

```bash
# What's actually running?
az resource list -g "$RG" \
  --query "[?type!='Microsoft.Network/networkWatchers'].[type,name]" -o table

# Is auto-shutdown firing? (last 20 events)
az monitor activity-log list -g "$RG" --max-events 20 \
  --query "[?operationName.value=='Microsoft.Compute/virtualMachines/deallocate/action'].{when:eventTimestamp,who:caller}"

# Forecast for the rest of the month — opens the Cost Management view
# scoped to this RG:
echo "https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/%2Fsubscriptions%2F$(az account show --query id -o tsv)%2FresourceGroups%2F$RG"
```

---

## What's next (v2 backlog)

After v1 is stable, candidates for v2 (in spec §"Out of Scope"):

- Logic-App auto-start so the VM wakes at 08:00 PT.
- Tailscale auth-key auto-rotation.
- Customer-managed encryption keys.
- Packer image bake (replaces cloud-init).
- Monitoring + alerting on unexpected downtime.
