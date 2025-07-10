init:
  [ -f ~/.ssh/fort ] || ssh-keygen -t ed25519 -f ~/.ssh/fort
  just _toml_set config.toml "fort.pubkey" "$(< ~/.ssh/fort.pub)"

provision $profile $ssh_target:
  #!/bin/bash
  set -euo pipefail

  uuid=$(
    ssh -i ~/.ssh/fort \
    -o StrictHostKeyChecking=no \
    $ssh_target "sudo cat /sys/class/dmi/id/product_uuid"
  )
  mkdir -p ./devices/$uuid

  just _toml_set config.toml "devices.$uuid.profile" $profile
  just _toml_set config.toml "devices.$uuid.system" x86_64-linux

  nix run github:nix-community/nixos-anywhere -- \
    --generate-hardware-config nixos-generate-config ./devices/$uuid/hardware-configuration.nix \
    --flake .#$uuid \
    -i ~/.ssh/fort \
    --target-host $ssh_target

  ssh-keygen -R "${ssh_target#*@}" 2>/dev/null

_toml_set FILE PATH VALUE:
  #!/bin/bash
  set -euo pipefail
  touch "{{FILE}}"
  tmp=$(mktemp)
  nix run nixpkgs#toml-cli -- set "{{FILE}}" "{{PATH}}" "{{VALUE}}" > $tmp
  mv $tmp "{{FILE}}"
