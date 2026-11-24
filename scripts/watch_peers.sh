#!/bin/bash
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"
STATE="/var/lib/myvpn/handshakes"
IDLE=180

if [[ ! -f /etc/myvpn/notify.env ]]; then
  echo "/etc/myvpn/notify.env is missing, no notification sent" >&2
  exit 1
fi
source /etc/myvpn/notify.env

current=$(wg show wg0 latest-handshakes)

if [[ ! -f "$STATE" ]]; then
  mkdir -p "$(dirname "$STATE")"
  printf '%s\n' "$current" > "$STATE"
  exit 0
fi

while read -r pub hs; do
  if [[ -z "$pub" || "$hs" -eq 0 ]]; then
    continue
  fi
  prev=$(awk -v k="$pub" '$1 == k { print $2 }' "$STATE")
  if [[ -n "$prev" ]] && (( hs - prev <= IDLE )); then
    continue
  fi
  name=$(awk -v k="$pub" '
    /^# Client: / { n = substr($0, 11) }
    /^PublicKey/ { if ($3 == k) { print n; exit } n = "" }
  ' "$WG_CONF")
  ip=$(wg show wg0 allowed-ips | awk -v k="$pub" '$1 == k { print $2 }')
  msg="${name:-unnamed} (${ip%/32}) connected at $(date -u -d "@$hs" +%H:%M) UTC"
  echo "$msg"
  curl -fsS -m 10 -H "Title: MyVPN" -d "$msg" "$NTFY_URL" > /dev/null || echo "Notification failed" >&2
done <<< "$current"

printf '%s\n' "$current" > "$STATE"
