#!/usr/bin/env bash
set -euo pipefail

DEVICE=${1:?Usage: write-drive.sh /dev/sdX}
[[ -b "$DEVICE" ]] || { echo "Not a block device: $DEVICE" >&2; exit 1; }
[[ "$DEVICE" == /dev/* ]] || { echo "Refusing non-/dev path" >&2; exit 1; }

if findmnt -rn -S "${DEVICE}*" >/dev/null 2>&1; then
  echo "Refusing to overwrite a mounted device or partition of $DEVICE" >&2
  findmnt -rn -S "${DEVICE}*" >&2 || true
  exit 1
fi

size=$(lsblk -dn -o SIZE "$DEVICE")
model=$(lsblk -dn -o MODEL "$DEVICE" | xargs)
serial=$(lsblk -dn -o SERIAL "$DEVICE" | xargs)
transport=$(lsblk -dn -o TRAN "$DEVICE" | xargs)

if [[ "$transport" != "usb" && "${FORT_ALLOW_NON_USB:-}" != "1" ]]; then
  echo "Refusing $DEVICE: transport is '${transport:-unknown}', not usb." >&2
  echo "Set FORT_ALLOW_NON_USB=1 only for deliberate VM/test targets." >&2
  exit 1
fi

cat <<EOF
FORT BOOT DRIVE WRITER

  device:    $DEVICE
  model:     ${model:-unknown}
  serial:    ${serial:-unknown}
  size:      ${size:-unknown}
  transport: ${transport:-unknown}

This irreversibly overwrites the entire device and embeds the fleet bootstrap
credential. Anyone holding this USB can contend for an armed provisioning lease.
EOF
printf '\nType the exact device path (%s) to continue: ' "$DEVICE"
read -r answer
[[ "$answer" == "$DEVICE" ]] || { echo "Cancelled."; exit 1; }

: "${FORT_BOOTSTRAP_SECRET_FILE:?Set FORT_BOOTSTRAP_SECRET_FILE to the fleet secret file}"
[[ -s "$FORT_BOOTSTRAP_SECRET_FILE" ]] || { echo "Secret file is empty" >&2; exit 1; }

result=$(nix build --impure ./provisioning/boot#default --no-link --print-out-paths)
iso=$(printf '%s\n' "$result"/iso/*.iso)
echo "Writing $iso to $DEVICE ..."
sudo dd if="$iso" of="$DEVICE" bs=16M conv=fsync status=progress
sync
echo "Fort provisioning drive ready: $DEVICE"
