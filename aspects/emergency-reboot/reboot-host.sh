#!/usr/bin/env bash
# Usage: reboot-host <host-ip> [secret-file]
# Sends an authenticated UDP reboot command to the emergency listener.
set -euo pipefail

HOST="${1:?Usage: reboot-host <host-ip> [secret-file]}"
SECRET_FILE="${2:-/run/agenix/reboot-secret}"
PORT=9999

if [ ! -f "$SECRET_FILE" ]; then
  echo "Error: secret file not found: $SECRET_FILE" >&2
  echo "On dev-sandbox, try: age -d -i ~/.config/age/keys.txt aspects/emergency-reboot/reboot-secret.age" >&2
  exit 1
fi

SECRET=$(cat "$SECRET_FILE")
TS=$(date +%s)
MAC=$(echo -n "$TS" | openssl dgst -sha256 -hmac "$SECRET" -hex 2>/dev/null | awk '{print $NF}')

echo "Sending reboot to ${HOST}:${PORT}..."
echo -n "${TS}.${MAC}" | nc -u -w2 "$HOST" "$PORT"
echo "Sent. Host should reboot momentarily."
