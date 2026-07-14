#!/usr/bin/env bash
set -euo pipefail

ISO=${1:?Usage: vm-smoke.sh path/to/fort.iso}
[[ -f "$ISO" ]] || { echo "ISO not found: $ISO" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 is required" >&2; exit 1; }

log=$(mktemp)
trap 'rm -f "$log"' EXIT

timeout 120 qemu-system-x86_64 \
  -machine accel=kvm:tcg -m 1536 -smp 2 \
  -cdrom "$ISO" -boot d -no-reboot -nographic \
  -serial mon:stdio >"$log" 2>&1 || status=$?

if grep -q 'FORT //' "$log"; then
  echo "PASS: ISO reached the unattended provisioning client"
  grep 'FORT //' "$log" | tail -5
  exit 0
fi

echo "FAIL: boot marker was not observed" >&2
tail -100 "$log" >&2
exit 1
