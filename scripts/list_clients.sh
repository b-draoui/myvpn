#!/bin/bash
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run this script as root (using sudo)." >&2
  exit 1
fi

row() {
  printf "%-20s %-12s %-14s %-10s %-10s\n" "$@"
}

ago() {
  local s=$1
  if (( s < 60 )); then
    echo "${s}s ago"
  elif (( s < 3600 )); then
    echo "$(( s / 60 ))m ago"
  elif (( s < 86400 )); then
    echo "$(( s / 3600 ))h ago"
  else
    echo "$(( s / 86400 ))d ago"
  fi
}

now=$(date +%s)

row "NAME" "IP" "HANDSHAKE" "RECEIVED" "SENT"

wg show wg0 dump | tail -n +2 | while IFS=$'\t' read -r pub _ _ ips handshake rx tx _; do
  name=$(awk -v k="$pub" '
    /^# Client: / { n = substr($0, 11) }
    /^PublicKey/ { if ($3 == k) { print n; exit } n = "" }
  ' "$WG_CONF")

  if [[ "$handshake" -eq 0 ]]; then
    seen="never"
  else
    seen=$(ago "$(( now - handshake ))")
  fi

  row "${name:--}" "${ips%/32}" "$seen" \
    "$(numfmt --to=iec --suffix=B "$rx")" "$(numfmt --to=iec --suffix=B "$tx")"
done