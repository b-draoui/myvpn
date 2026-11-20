# MyVPN

A personal WireGuard VPN on Azure, deployed with Terraform and cloud-init. I built it to learn networking and security, starting from a VirtualBox lab and ending with a hardened server that rebuilds itself from these files.

The write-up comes in two parts:

- [MyVPN Server Setup](docs/MyVPN_Server_Setup.pdf): the lab, the WireGuard configuration, Azure, the client scripts and Terraform.
- [MyVPN Server Security](docs/MyVPN_Server_Security.pdf): the threat model, the hardening and the security tests.

## What it does

- Full-tunnel VPN: clients send all their traffic through the server (`0.0.0.0/0, ::/0`).
- Client management in one command: `add_client.sh`, `remove_client.sh` and `list_clients.sh`.
- Testers expire on their own: 7 days by default, removed every night by a systemd timer.
- Each client has its own preshared key, and the server never keeps a tester's private key: their config is shown once and forgotten.
- Hardened from first boot:
  - The NSG only lets UDP 51820 in, and a host firewall (nftables) drops everything else, even if the NSG is opened by mistake.
  - Clients can't reach each other, Azure's internal addresses or any private range, and can't send mail (port 25) or use Windows file sharing through the server.
  - SSH only works through the tunnel, and only from the admin client (10.8.0.2).
  - DNS goes through the server's own resolver (Unbound), encrypted up to Cloudflare and checked with DNSSEC. DNS queries sent to any other server are redirected to it.
  - Security updates install every day, and the server reboots on its own at 04:00 UTC when a new kernel needs it.
  - Hardened sshd, kernel settings, unused network protocols and core dumps.
- Monitored:
  - Packets dropped by the firewall are logged (`myvpn-drop:` in the journal), with a rate limit so a scan can't fill the disk. The journal keeps 14 days and 200 MB at most.
  - Azure sends an email when someone changes the NSG or uses Run Command on the VM.
  - A phone notification (ntfy) arrives every time a client connects.
- The Ubuntu image is pinned to one version, so two deploys of the same commit build the same server.

## Files

| File | Role |
|---|---|
| `main.tf` | Azure provider and resource group |
| `variables.tf` | Subscription, region, VM size, username, keys, image version, alert email |
| `network.tf` | Virtual network, subnet, public IP, NSG and network card |
| `vm.tf` | The Ubuntu 24.04 VM and the cloud-init data |
| `monitoring.tf` | The email alerts: an action group and two activity log alerts |
| `cloud-init.yaml.tftpl` | First boot: WireGuard, firewall, DNS resolver, hardening, scripts |
| `scripts/` | The client scripts (add, remove, list), the nightly expiry check and the connection notifier |
| `terraform.tfvars.example` | The values to fill in |
| `backend.tf.example` | Optional: keep the Terraform state in an Azure storage account instead of on your PC |

## Deploy

You need an Azure subscription (Azure for Students works), Terraform, the Azure CLI, an SSH key pair and the WireGuard app.

1. Clone the repo and fill in `terraform.tfvars`: the subscription ID, a username, the public key of the WireGuard tunnel that will be the admin, and the email that gets the alerts. In the WireGuard app, adding an empty tunnel generates that key pair.

   ```
   git clone https://github.com/b-draoui/myvpn
   cd myvpn
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Deploy:

   ```
   az login
   terraform init
   terraform apply
   ```

   The default size is `Standard_B2ats_v2`, which the Azure for Students free hours cover. If it has no capacity, `-var="vm_size=..."` picks another size, but the paid sizes are billed by the hour. If an apply fails with `AllocationFailed`, Azure can leave an empty VM behind, and the next apply refuses to create one with the same name. Delete it first:

   ```
   az vm delete -g myvpn-tf-rg -n myvpn-tf-vm --yes
   az disk list -g myvpn-tf-rg --query "[?diskState=='Unattached'].name" -o tsv
   az disk delete -g myvpn-tf-rg -n <disk name> --yes
   ```

   If it fails with `MissingSubscriptionRegistration` on the alerts, register the monitoring provider once with `az provider register -n Microsoft.Insights` and apply again.

   After the apply, Azure sends a verification email to the alert address. Until it's confirmed, the alerts fire but no email leaves.

3. Get the server's public key and the admin's preshared key without SSH, since port 22 is closed:

   ```
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cloud-init status --wait; cat /etc/wireguard/server.pub; grep -A3 '# Client: admin' /etc/wireguard/wg0.conf | grep PresharedKey" --query "value[0].message" -o tsv
   ```

   The preshared key is a secret: don't share or screenshot that output.

   The connection notifications go to a random ntfy topic created at first boot. Get it the same way and subscribe to it in the ntfy app:

   ```
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cat /etc/myvpn/notify.env" --query "value[0].message" -o tsv
   ```

   Anyone who knows the topic can read it, so keep it private too. Both Run Commands will trigger the Run Command alert email, which is a good way to check it works.

4. Finish the admin tunnel in the WireGuard app and turn on the kill switch (block untunneled traffic):

   ```
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

5. Connect, then add testers through SSH inside the tunnel:

   ```
   ssh <username>@10.8.0.1
   sudo add_client.sh <name>
   ```

   `add_client.sh <name> [qr|text] [days]` shows the config as a QR code (default) or as text, and sets the end date (7 days by default, 0 to 90). `list_clients.sh` shows who's connected, and `remove_client.sh <name>` removes a tester before their end date.

6. When you're done, `terraform destroy` removes everything.

### Optional: remote state

By default the state stays in `terraform.tfstate` on your PC. To keep it in Azure instead (encrypted, versioned, and locked while an apply runs), create a storage account with shared keys disabled and a `tfstate` container, give yourself the "Storage Blob Data Contributor" role on it, then:

```
cp backend.tf.example backend.tf
terraform init -migrate-state
```

`backend.tf` is in `.gitignore` because it names your storage account.

## Limits

- The VPN server, and Azure, can see which destinations the traffic goes to. A VPN moves the trust from the ISP to the server but doesn't remove it.
- It doesn't protect against a compromised client device or tracking by websites.
- A browser using DNS over HTTPS can still reach its own resolver: it looks like normal HTTPS traffic, so the server can't redirect it.
- IPv6 isn't carried through the tunnel. Clients only avoid IPv6 leaks if their config keeps `::/0` in AllowedIPs and the kill switch on.
- `terraform.tfstate` contains sensitive values. It's in `.gitignore`, keep it that way.
- ntfy.sh is a public service: the notification text (client name, tunnel IP, time) passes through it.
