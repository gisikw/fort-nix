domain := `nix run nixpkgs#toml-cli -- get config.toml -r fort.domain`

init:
  [ -f ~/.ssh/fort ] || ssh-keygen -t ed25519 -f ~/.ssh/fort -C "fort"
  just _toml_set config.toml "fort.pubkey" "$(< ~/.ssh/fort.pub)"

provision $profile $ssh_target:
  #!/bin/bash
  set -euo pipefail

  uuid=$(
    ssh -i ~/.ssh/fort \
    -o StrictHostKeyChecking=no \
    $ssh_target '
      command -v sudo >/dev/null &&
      sudo cat /sys/class/dmi/id/product_uuid ||
      cat /sys/class/dmi/id/product_uuid
    '
  )
  mkdir -p ./devices/$uuid

  temp=$(mktemp -d)
  cleanup() {
    rm -rf "$temp"
  }
  trap cleanup EXIT

  install -d -m755 "$temp/etc/ssh"
  ssh-keygen -t ed25519 \
    -N "" \
    -C "fort-device-${uuid}" \
    -f "$temp/etc/ssh/ssh_host_ed25519_key"

  just _toml_set config.toml "devices.$uuid.profile" $profile
  just _toml_set config.toml "devices.$uuid.system" "x86_64-linux"
  just _toml_set config.toml "devices.$uuid.pubkey" "$(cat $temp/etc/ssh/ssh_host_ed25519_key.pub)"

  nix run github:ryantm/agenix -- -i ~/.ssh/fort -r

  nix run github:nix-community/nixos-anywhere -- \
    --generate-hardware-config nixos-generate-config ./devices/$uuid/hardware-configuration.nix \
    --extra-files "$temp" \
    --flake .#$uuid \
    -i ~/.ssh/fort \
    --target-host $ssh_target

  ssh-keygen -R "${ssh_target#*@}" >/dev/null 2>&1

list-devices:
  nix run nixpkgs#toml-cli -- get config.toml . | nix run nixpkgs#jq -- -r '.devices | keys'

list-hosts:
  nix run nixpkgs#toml-cli -- get config.toml . | nix run nixpkgs#jq -- -r '.hosts | keys'

assign $device $host:
  just _toml_set config.toml "hosts.$host.device" $device

deploy host addr=(host + ".hosts." + domain):
  nix run github:serokell/deploy-rs -- -d --hostname {{addr}} --remote-build .#{{host}}

_toml_set FILE PATH VALUE:
  #!/bin/bash
  set -euo pipefail
  touch "{{FILE}}"
  tmp=$(mktemp)
  nix run nixpkgs#toml-cli -- set "{{FILE}}" "{{PATH}}" "{{VALUE}}" > $tmp
  mv $tmp "{{FILE}}"
