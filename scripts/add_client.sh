#!/bin/bash
set -euo pipefail

ENDPOINT="127.0.0.1:51820"
CLIENT_ALLOWED_IPS="10.8.0.0/24"
DNS="1.1.1.1"
CLIENTS_DIR="/etc/wireguard/clients"

if [[ -f /etc/wireguard/myvpn.env ]]; then
  source /etc/wireguard/myvpn.env
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (using sudo)." >&2
  exit 1
fi

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "No name was given" >&2
  exit 1
fi
if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Invalid name: use only letters, digits, - and _" >&2
  exit 1
fi

client_conf="$CLIENTS_DIR/${name}.conf"
if [[ -e "$client_conf" ]]; then
  echo "Client '$name' already exists" >&2
  exit 1
fi

umask 077
mkdir -p "$CLIENTS_DIR"

priv=$(wg genkey)
pub=$(echo "$priv" | wg pubkey)
server_pub=$(wg show wg0 public-key)

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

wg set wg0 peer "$pub" allowed-ips "$available_ip/32"

cat >> /etc/wireguard/wg0.conf <<EOF

# Client: $name
[Peer]
PublicKey = $pub
AllowedIPs = $available_ip/32
EOF

cat > "$client_conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $available_ip/32
DNS = $DNS

[Peer]
PublicKey = $server_pub
Endpoint = $ENDPOINT
AllowedIPs = $CLIENT_ALLOWED_IPS
PersistentKeepalive = 25
EOF

echo "Client '$name' created with address $available_ip"
echo "Config saved in $client_conf"
qrencode -t ansiutf8 < "$client_conf"
