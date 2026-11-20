#!/bin/bash
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (using sudo)." >&2
  exit 1
fi

now=$(date +%s)
list=$(awk '
  /^# Client: / { name = substr($0, 11) }
  /^# Expires: / { print name, substr($0, 12) }
' "$WG_CONF")

while read -r name expires; do
  if [[ -z "$name" ]]; then
    continue
  fi
  if (( $(date -d "$expires" +%s) <= now )); then
    echo "Client '$name' expired on $expires"
    /usr/local/sbin/remove_client.sh "$name"
  fi
done <<< "$list"
