#!/bin/bash
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"

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

pub=$(awk -v n="# Client: $name" '
  $0 == n { found = 1; next }
  found && /^PublicKey/ { print $3; exit }
' "$WG_CONF")

if [[ -z "$pub" ]]; then
  echo "Client '$name' not found in $WG_CONF" >&2
  exit 1
fi

wg set wg0 peer "$pub" remove

umask 077
tmp=$(mktemp "${WG_CONF}.XXXXXX")
awk -v n="# Client: $name" '
  $0 == n { skip = 1; next }
  skip && /^[[:space:]]*$/ { skip = 0 }
  skip { next }
  { print }
' "$WG_CONF" | cat -s > "$tmp"
mv "$tmp" "$WG_CONF"

echo "Client '$name' removed"
