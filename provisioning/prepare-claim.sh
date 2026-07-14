#!/usr/bin/env bash
set -euo pipefail
completion=${1:?completion JSON required}
repo=${FORT_PROVISION_REPO:-/var/lib/fort-nix}
host=$(jq -er .host "$completion")
uuid=$(jq -er .uuid "$completion")
profile=$(jq -er .profile "$completion")
pubkey=$(jq -er .pubkey "$completion")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Build a private, claim-specific source tree. This is deliberately not a Git
# mutation: the durable registrar remains an explicit reviewed step.
tar -C "$repo" --exclude=.git --exclude=result -cf - . | tar -C "$work" -xf -
dev="$work/clusters/bedlam/devices/$uuid"
manifest="$work/clusters/bedlam/hosts/$host/manifest.nix"
mkdir -p "$dev"
jq -er .hardware_configuration "$completion" > "$dev/hardware-configuration.nix"
cp "$work/provisioning/device-flake.nix" "$dev/flake.nix"
state=$(nix eval --raw nixpkgs#lib.version | cut -d. -f1,2)
printf "{ uuid = \"%s\"; profile = \"%s\"; pubkey = ''%s''; stateVersion = \"%s\"; }\n" "$uuid" "$profile" "$pubkey" "$state" > "$dev/manifest.nix"
python3 - "$manifest" "$uuid" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); old='device = "pending";'
if old not in s: raise SystemExit(f"{p}: expected {old}")
p.write_text(s.replace(old, f'device = "{sys.argv[2]}";', 1))
PY

# The future host key must become a recipient before first boot; otherwise the
# assigned configuration would install but fail to decrypt mesh/GitOps secrets.
(
  cd "$work"
  export SOPS_AGE_SSH_PRIVATE_KEY_FILE=/etc/ssh/ssh_host_ed25519_key
  nix shell nixpkgs#sops nixpkgs#ssh-to-age nixpkgs#jq --command bash scripts/rekey.sh
)

tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
  --exclude=.git --exclude=result -C "$work" -czf "${completion%.json}.tar.gz" .
chmod 0600 "${completion%.json}.tar.gz"
