#!/usr/bin/env bash
set -euo pipefail
host=${1:?Usage: register-completion.sh <host>}
cluster=$(nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).clusterName')
completion="/var/lib/fort-provisioner/completions/${host}.json"

if [[ ! -r "$completion" ]]; then
  echo "Completion is on the provisioner host. Copy it locally first or run this command there:" >&2
  echo "  $completion" >&2
  exit 1
fi

uuid=$(jq -er .uuid "$completion")
profile=$(jq -er .profile "$completion")
pubkey=$(jq -er .pubkey "$completion")
dev="clusters/$cluster/devices/$uuid"
manifest="clusters/$cluster/hosts/$host/manifest.nix"
[[ -f "$manifest" ]] || { echo "Unknown host $host" >&2; exit 1; }
[[ ! -e "$dev" ]] || { echo "Device already exists: $dev" >&2; exit 1; }

echo "Registering $host -> $uuid ($profile)"
mkdir -p "$dev"
jq -er .hardware_configuration "$completion" > "$dev/hardware-configuration.nix"
cp provisioning/device-flake.nix "$dev/flake.nix"
state=$(nix eval --raw nixpkgs#lib.version | cut -d. -f1,2)
printf '{ uuid = "%s"; profile = "%s"; pubkey = '\'''%s'\''; stateVersion = "%s"; }\n' "$uuid" "$profile" "$pubkey" "$state" > "$dev/manifest.nix"
python3 - "$manifest" "$uuid" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); old='device = "pending";'
if old not in s: raise SystemExit(f"{p}: expected {old}")
p.write_text(s.replace(old, f'device = "{sys.argv[2]}";', 1))
PY
(cd "$dev" && nix flake lock)
git add "$dev" "$manifest"
echo "Staged. Review with: git diff --staged"
