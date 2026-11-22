# MyVPN

A ready-to-deploy, self-hosted WireGuard VPN on Azure. MyVPN automates the infrastructure, first-boot provisioning, server hardening and client lifecycle so an operator can deploy a managed VPN instance without assembling every component by hand.

**Self-hosted deployment:** each operator deploys and owns a separate instance in their own Azure subscription. You are responsible for Azure costs, credentials, access control, updates, backups and ongoing operation. MyVPN is software and deployment automation, not a centrally operated VPN service.

The [MyVPN Deployment & Operations Manual](docs/MyVPN_Deployment_Manual.pdf) is the primary guide for prerequisites, deployment, administration, security boundaries, troubleshooting and teardown.

## What it does

- Full-tunnel VPN: clients send all their traffic through the server (`0.0.0.0/0, ::/0`).
- Client management in one command: `add_client.sh`, `remove_client.sh` and `list_clients.sh`.
- Temporary clients expire automatically: 7 days by default, with a configurable duration, removed nightly by a systemd timer.
- Each client has its own preshared key, and the server never keeps a tester's private key: their config is shown once and forgotten.
- Hardened from first boot:
  - The NSG only lets UDP 51820 in, and a host firewall (nftables) drops everything else, even if the NSG is opened by mistake.
  - Clients can't reach each other, Azure's internal addresses or any private range, and can't send mail (port 25) or use Windows file sharing through the server.
  - SSH only works through the tunnel, and only from the admin client (`10.8.0.2`).
  - DNS goes through the server's own resolver (Unbound), encrypted up to Cloudflare and checked with DNSSEC. DNS queries sent to any other server are redirected to it.
  - Security updates install every day, and the server reboots automatically at 04:00 UTC when a new kernel requires it.
  - Hardened sshd, kernel settings, unused network protocols and core dumps.
- Monitored:
  - Packets dropped by the firewall are logged (`myvpn-drop:` in the journal), with a rate limit so a scan can't fill the disk. The journal keeps 14 days and 200 MB at most.
  - Azure sends an email when someone changes the NSG or uses Run Command on the VM.
  - Connection notifications are provided through ntfy; verify delivery on a clean deployment before relying on them.
- The Ubuntu image is pinned to one version, so two deploys of the same commit build the same server.

## Documentation

For complete deployment and operations instructions, see the [MyVPN Deployment & Operations Manual](docs/MyVPN_Deployment_Manual.pdf).

## Files

| File | Role |
|---|---|
| `main.tf` | Azure provider and resource group |
| `variables.tf` | Subscription, region, VM size, username, keys, image version, alert email |
| `network.tf` | Virtual network, subnet, public IP, NSG and network card |
| `vm.tf` | The Ubuntu 24.04 VM and the cloud-init data |
| `monitoring.tf` | Email alerts: an action group and two activity log alerts |
| `cloud-init.yaml.tftpl` | First boot: WireGuard, firewall, DNS resolver, hardening, scripts |
| `scripts/` | Client scripts (add, remove, list), nightly expiry check and connection notifier |
| `terraform.tfvars.example` | Example values to configure |
| `backend.tf.example` | Optional Azure Storage backend configuration for remote Terraform state |

## Deploy

You need an Azure subscription (Azure for Students works), Terraform, the Azure CLI, an SSH key pair and the WireGuard app.

1. Clone the repository and fill in `terraform.tfvars` with your subscription ID, a username, the public key of the WireGuard tunnel that will be the admin, and the email address that receives alerts. In the WireGuard app, adding an empty tunnel generates the required key pair.

   ```bash
   git clone https://github.com/b-draoui/myvpn
   cd myvpn
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Deploy:

   ```bash
   az login
   terraform init
   terraform apply
   ```

   The default VM size is `Standard_B2ats_v2`, which is covered by the Azure for Students eligible free-hour allowance. Availability and eligibility depend on your subscription and region. Other VM sizes may incur hourly charges.

   If an apply fails with `AllocationFailed`, Azure can leave an empty VM behind, and the next apply may refuse to create another VM with the same name. Check the resource group and remove the failed VM before retrying:

   ```bash
   az vm delete -g myvpn-tf-rg -n myvpn-tf-vm --yes
   az disk list -g myvpn-tf-rg --query "[?diskState=='Unattached'].name" -o tsv
   az disk delete -g myvpn-tf-rg -n <disk-name> --yes
   ```

   Only delete the unattached disk belonging to the failed deployment.

   If deployment fails with `MissingSubscriptionRegistration` on the alerts, register the monitoring provider once:

   ```bash
   az provider register -n Microsoft.Insights
   ```

   Then run `terraform apply` again.

   After deployment, Azure sends a verification email to the alert address. Until the email subscription is confirmed, alerts may fire without delivering email notifications.

3. Get the server's public key and the admin's preshared key without SSH, since port 22 is closed:

   ```bash
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cloud-init status --wait; cat /etc/wireguard/server.pub; grep -A3 '# Client: admin' /etc/wireguard/wg0.conf | grep PresharedKey" --query "value[0].message" -o tsv
   ```

   The preshared key is a secret. Do not share or screenshot that output.

   Connection notifications go to a randomly generated ntfy topic created at first boot. Retrieve it the same way and subscribe to it in the ntfy app:

   ```bash
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cat /etc/myvpn/notify.env" --query "value[0].message" -o tsv
   ```

   Anyone who knows the topic can read its notifications, so keep it private too. Both Run Commands trigger the Run Command alert email, providing a useful way to check alert delivery.

4. Finish configuring the admin tunnel in the WireGuard app and enable its kill switch (block traffic that is not sent through the tunnel):

   ```ini
   [Interface]
   PrivateKey = <generated by the app>
   Address = 10.8.0.2/32
   DNS = 10.8.0.1

   [Peer]
   PublicKey = <server public key>
   PresharedKey = <admin preshared key>
   Endpoint = <public IP>:51820
   AllowedIPs = 0.0.0.0/0, ::/0
   ```

5. Connect, then add temporary clients through SSH inside the tunnel:

   ```bash
   ssh <username>@10.8.0.1
   sudo add_client.sh <name>
   ```

   `add_client.sh <name> [qr|text] [days]` displays the client configuration as a QR code (default) or as text, and sets its expiry. The default is 7 days; the configurable duration is 0 to 90 days.

   - `list_clients.sh` shows client information and connection status.
   - `remove_client.sh <name>` removes a client before its expiry.
   - Expired clients are removed automatically by the nightly systemd timer.

6. When you're done, run:

   ```bash
   terraform destroy
   ```

   This removes the Terraform-managed infrastructure. Check the Azure resource group afterwards for any resources not managed by Terraform.

### Optional: Remote state

By default, Terraform state stays in `terraform.tfstate` on your PC. To keep it in Azure instead, create an Azure Storage account with shared keys disabled and a `tfstate` container. Azure Storage encrypts data at rest. Enable blob versioning separately to retain previous state versions. Terraform uses state locking to prevent concurrent operations.

Give your account the **Storage Blob Data Contributor** role on the storage account or appropriate container scope, then configure the backend:

```bash
cp backend.tf.example backend.tf
terraform init -migrate-state
```

`backend.tf` is in `.gitignore` because it identifies your storage account.

**Important:** Enable Azure Blob Storage versioning before using the container for Terraform state. Versioning helps recover previous state versions if the state file is accidentally changed or overwritten.

Restrict access to the storage account and state container. Terraform state may contain sensitive infrastructure information and must never be treated as public data.

## Limits

- The VPN server and Azure can see which destinations traffic goes to. A VPN moves trust from the ISP to the server and its cloud provider; it does not remove that trust.
- It does not protect against a compromised client device or tracking by websites.
- A browser using DNS over HTTPS can still reach its own resolver: DoH looks like normal HTTPS traffic, so the server cannot redirect it using ordinary DNS redirection.
- The server does not provide IPv6 internet routing. Clients should keep `::/0` in `AllowedIPs` and enable the kill switch to prevent traffic from bypassing the tunnel over IPv6.
- `terraform.tfstate` contains sensitive values. It is in `.gitignore`; keep it that way.
- ntfy.sh is a public service. Notification text, including client name, tunnel IP and time, passes through it. Anyone who obtains the topic can read its notifications.
