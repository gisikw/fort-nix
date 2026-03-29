#!/usr/bin/env bash
# fn-1f1e: Migrate a single .age file to sops binary format
#
# Usage: migrate-secret.sh <path.age>
#
# Prerequisites:
#   - .sops.yaml must already have a rule for the target .sops path
#   - Run `just rekey` first after updating module code
#
# The script:
#   1. Decrypts the .age file with the dev-sandbox age key
#   2. Encrypts as sops binary format (.sops)
#   3. Verifies round-trip (decrypt and compare)
#   4. Removes the original .age file
set -euo pipefail

AGE_KEY="${HOME}/.config/age/keys.txt"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${AGE_KEY}}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path.age> [path.age ...]" >&2
  exit 1
fi

if [[ ! -f "$AGE_KEY" ]]; then
  echo "ERROR: Age key not found at $AGE_KEY" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

migrate_one() {
  local age_file="$1"

  if [[ ! -f "$age_file" ]]; then
    echo "ERROR: $age_file not found" >&2
    return 1
  fi

  if [[ "$age_file" != *.age ]]; then
    echo "ERROR: $age_file does not have .age extension" >&2
    return 1
  fi

  # Derive the target .sops path
  local sops_file="${age_file%.age}.sops"

  echo "[migrate] $age_file -> $sops_file"

  # Step 1: Decrypt
  local plain="$tmpdir/$(basename "$age_file").plain"
  if ! age -d -i "$AGE_KEY" "$age_file" > "$plain" 2>/dev/null; then
    echo "ERROR: Failed to decrypt $age_file" >&2
    return 1
  fi

  local original_size
  original_size=$(wc -c < "$plain")
  echo "  Decrypted: ${original_size} bytes"

  # Step 2: Encrypt with sops (binary format)
  if ! sops -e --input-type binary --output-type binary "$plain" > "$sops_file" 2>/dev/null; then
    echo "ERROR: sops encrypt failed for $sops_file — is .sops.yaml up to date?" >&2
    rm -f "$sops_file"
    return 1
  fi

  # Step 3: Verify round-trip
  local verify="$tmpdir/$(basename "$age_file").verify"
  if ! sops -d --input-type binary --output-type binary "$sops_file" > "$verify" 2>/dev/null; then
    echo "ERROR: sops decrypt verification failed for $sops_file" >&2
    rm -f "$sops_file"
    return 1
  fi

  if ! cmp -s "$plain" "$verify"; then
    echo "ERROR: Round-trip mismatch for $sops_file" >&2
    rm -f "$sops_file"
    return 1
  fi

  echo "  Verified: round-trip OK"

  # Step 4: Remove original
  rm "$age_file"
  echo "  Removed: $age_file"
}

failed=0
for f in "$@"; do
  if ! migrate_one "$f"; then
    failed=$((failed + 1))
  fi
done

if [[ $failed -gt 0 ]]; then
  echo "[migrate] $failed file(s) failed" >&2
  exit 1
fi

echo "[migrate] Done"
