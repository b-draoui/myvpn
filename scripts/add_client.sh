#!/bin/bash
set -euo pipefail

ENDPOINT="127.0.0.1:51820"
CLIENT_ALLOWED_IPS="10.8.0.0/24"
DNS="1.1.1.1"
WG_CONF="/etc/wireguard/wg0.conf"

if [[ -f /etc/wireguard/myvpn.env ]]; then
  source /etc/wireguard/myvpn.env
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (using sudo)." >&2
  exit 1
fi

name="${1:-}"
mode="${2:-qr}"
days="${3:-7}"
if [[ -z "$name" ]]; then
  echo "No name was given" >&2
  exit 1
fi
if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Invalid name: use only letters, digits, - and _" >&2
  exit 1
fi
if [[ "$mode" != "qr" && "$mode" != "text" ]]; then
  echo "Usage: add_client.sh <name> [qr|text] [days]" >&2
  exit 1
fi
if [[ ! "$days" =~ ^[0-9]+$ ]] || (( 10#$days > 90 )); then
  echo "Days must be a number from 0 to 90" >&2
  exit 1
fi
if grep -qxF "# Client: $name" "$WG_CONF"; then
  echo "Client '$name' already exists" >&2
  exit 1
fi

priv=$(wg genkey)
pub=$(printf '%s\n' "$priv" | wg pubkey)
psk=$(wg genpsk)
server_pub=$(wg show wg0 public-key)
expires=$(date -d "+$((10#$days)) days" +%F)

used=$(wg show wg0 allowed-ips)
available_ip=""
for i in {2..254}; do
  ip="10.8.0.$i"
  if ! grep -Fq "$ip/" <<< "$used"; then
    available_ip="$ip"
    break
  fi
done
if [[ -z "$available_ip" ]]; then
  echo "Error: No available IP addresses in 10.8.0.2-254" >&2
  exit 1
fi

wg set wg0 peer "$pub" preshared-key <(printf '%s\n' "$psk") allowed-ips "$available_ip/32"

cat >> "$WG_CONF" <<EOF

# Client: $name
# Expires: $expires
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $available_ip/32
EOF

conf="[Interface]
PrivateKey = $priv
Address = $available_ip/32
DNS = $DNS

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $ENDPOINT
AllowedIPs = $CLIENT_ALLOWED_IPS
PersistentKeepalive = 25"

echo "Client '$name' created with address $available_ip, expires on $expires at 00:00 UTC"
if [[ "$mode" == "text" ]]; then
  printf '%s\n' "$conf"
else
  printf '%s\n' "$conf" | qrencode -t ansiutf8
fi
echo "Shown only once: the server doesn't keep this config."
