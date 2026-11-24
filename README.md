# MyVPN

A personal WireGuard VPN on Azure, deployed with Terraform and cloud-init. I built it to learn networking and security, starting from a VirtualBox lab and ending with a hardened server that rebuilds itself from these files.

It's self-hosted: anyone can deploy their own copy in their own Azure subscription. There's no central service behind it. Whoever deploys it owns the server, its keys and its cost, and is the one who decides who can connect.

The [MyVPN Deployment Manual](docs/MyVPN_Deployment_Manual.pdf) covers everything in detail: deployment, client management, the security model, monitoring, the Terraform state, maintenance, troubleshooting and teardown.

How I built it, and why each piece is there, is in two write-ups:

- [MyVPN Server Setup](docs/MyVPN_Server_Setup.pdf): the lab, the WireGuard configuration, Azure, the client scripts and Terraform.
- [MyVPN Server Security](docs/MyVPN_Server_Security.pdf): the threat model, the hardening, the monitoring and the security tests.

## What it does

- Full-tunnel VPN: clients send all their traffic through the server (`0.0.0.0/0, ::/0`).
- Client management in one command: `add_client.sh`, `remove_client.sh` and `list_clients.sh`.
- Clients expire on their own: 7 days by default, up to 90, removed every night at midnight UTC by a systemd timer.
- Each client has its own preshared key, and the server never keeps a client's private key: their config is shown once and forgotten.
- Hardened from first boot:
  - The NSG only lets UDP 51820 in, and a host firewall (nftables) drops everything else, even if the NSG is opened by mistake.
  - Clients can't reach each other, Azure's internal addresses or any private range, and can't send mail (port 25) or use Windows file sharing through the server.
  - SSH only works through the tunnel, and only from the admin client (10.8.0.2).
  - DNS goes through the server's own resolver (Unbound), encrypted up to Cloudflare and checked with DNSSEC. DNS queries sent to any other server on port 53 are redirected to it, and DNS over TLS and over QUIC on port 853 are blocked.
  - Security updates install every day, and the server reboots on its own at 04:00 UTC when an update needs it.
  - Hardened sshd, kernel settings, unused network protocols and core dumps.
- Monitored:
  - Packets dropped by the firewall are logged (`myvpn-drop:` in the journal), with a rate limit so a scan can't fill the disk. The journal keeps 14 days and 200 MB at most.
  - Azure sends an email when someone changes the NSG or uses Run Command on the VM.
  - A phone notification (ntfy) arrives when a client connects.
- The Ubuntu image is pinned to one version, so every deployment starts from the same tested image. First boot still installs the latest updates.

## Files

| File | Role |
|---|---|
| `main.tf` | Azure provider and resource group |
| `variables.tf` | Subscription, region, VM size, username, keys, image version, alert email |
| `network.tf` | Virtual network, subnet, public IP, NSG and network card |
| `vm.tf` | The Ubuntu 24.04 VM and the cloud-init data |
| `monitoring.tf` | The email alerts: an action group and two Activity Log alerts |
| `cloud-init.yaml.tftpl` | First boot: WireGuard, firewall, DNS resolver, hardening, scripts |
| `scripts/` | The client scripts (add, remove, list), the nightly expiry check and the connection notifier |
| `terraform.tfvars.example` | The values to fill in |
| `backend.tf.example` | Optional: keep the Terraform state in Azure Storage instead of on your PC |
| `docs/` | The deployment manual and the two write-ups |

## Deploy

You need an Azure subscription (Azure for Students works), Terraform, the Azure CLI, an SSH key pair and the WireGuard app. Check the costs first: the default size, `Standard_B2ats_v2`, is in Azure's free monthly amounts on eligible accounts, but the disk and the public IP are billed (manual, 2.5).

1. Clone the repo and fill in `terraform.tfvars`: the subscription ID, the public key of the WireGuard tunnel that will be the admin, and the email that gets the alerts. The Linux user is `azureuser` unless you set `admin_username`. In the WireGuard app, adding an empty tunnel generates the admin key pair.

   ```
   git clone https://github.com/b-draoui/myvpn
   cd myvpn
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Deploy:

   ```
   az login
   terraform init
   terraform plan
   terraform apply
   ```

   If it fails with `AllocationFailed` (no capacity for that size) or `MissingSubscriptionRegistration` (a resource provider isn't registered), see section 9.1 of the manual. After the apply, Azure sends a confirmation email to the alert address. If it asks you to verify the address, do it, or the alert emails won't reach you.

3. Get the server's public key and the admin's preshared key without SSH, since port 22 is closed:

   ```
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cloud-init status --wait; cat /etc/wireguard/server.pub; grep -A3 '# Client: admin' /etc/wireguard/wg0.conf | grep PresharedKey" --query "value[0].message" -o tsv
   ```

   The preshared key is a secret: don't share or screenshot that output. Every Run Command also sends you an alert email, which is a good way to check that the alerts work.

   The connection notifications go to a random ntfy topic created at first boot. Get it the same way and subscribe to it in the ntfy app. Anyone who knows the topic can read it, so keep it private too:

   ```
   az vm run-command invoke -g myvpn-tf-rg -n myvpn-tf-vm --command-id RunShellScript --scripts "cat /etc/myvpn/notify.env" --query "value[0].message" -o tsv
   ```

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

5. Connect, then add clients through SSH inside the tunnel:

   ```
   ssh <username>@10.8.0.1
   sudo add_client.sh <name>
   ```

   `add_client.sh <name> [qr|text] [days]` shows the config as a QR code (default) or as text, and sets the lifetime (7 days by default, 0 to 90). `list_clients.sh` shows who's connected, and `remove_client.sh <name>` removes a client before its end date.

6. When you're done, turn the tunnel off, then run `terraform destroy`. With the kill switch on, deleting the server cuts your PC's internet and the destroy can fail halfway.

### Optional: remote state

By default, the state stays in `terraform.tfstate` on your PC. You can keep it in Azure Storage instead: Azure encrypts it at rest and locks it while an apply runs, and if you turn on blob versioning, older copies can be restored. Versioning isn't on by default, so the commands in section 7.2 of the manual turn it on, along with a storage account that has shared keys and public access disabled. Then:

```
cp backend.tf.example backend.tf
terraform init -migrate-state
```

`backend.tf` is in `.gitignore` because it names your storage account.

## Good to know

- cloud-init only runs at first boot. Changing `cloud-init.yaml.tftpl`, a script in `scripts/` or the image version changes the VM's custom data, and Terraform replaces the VM: new keys, so every client config stops working. Always read `terraform plan` before applying.
- Your Azure account is the real key to the server: Run Command runs any command as root without SSH. The alerts tell you when it's used, they don't stop it. Protect the account with MFA.

## Limits

- The VPN server, and Azure, can see which destinations the traffic goes to. A VPN moves the trust from the ISP to the server but doesn't remove it.
- It doesn't protect against a compromised client device or tracking by websites.
- A browser using DNS over HTTPS can still reach its own resolver: it looks like normal HTTPS traffic, so the server can't redirect it. The same goes for DNS over TLS or QUIC on a port other than 853.
- IPv6 isn't routed to the internet. Clients only avoid IPv6 leaks if their config keeps `::/0` in AllowedIPs and the kill switch on.
- `terraform.tfstate` contains sensitive values. It's in `.gitignore`, keep it that way.
- ntfy.sh is a public service: the notification text (client name, tunnel IP, time) passes through it.
