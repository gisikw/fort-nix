ssh := "ssh -i ~/.ssh/fort -o StrictHostKeyChecking=no"
domain := `nix eval --raw --expr '(import ./manifest.nix).fortConfig.settings.domain' --impure`

provision profile target:
  #!/usr/bin/env bash
  echo "[Fort] Provisioning target at {{target}}"
  if [ "{{profile}}" = "linode" ]; then
    uuid=$(just _fingerprint-linode {{target}} | tail -n1 | tr -d '\r\n')
  else
    uuid=$(just _fingerprint-hardware {{target}} | tail -n1 | tr -d '\r\n')
  fi
  keydir=$(just _generate-device-keys $uuid | tail -n1)
  just _scaffold-device-flake {{profile}} $uuid $keydir
  just _bootstrap-device {{target}} $uuid $keydir
  just _cleanup-device-provisioning $uuid {{target}} $keydir

_fingerprint-hardware target:
  echo "[Fort] Fingerprinting physical hardware"
  {{ssh}} root@{{target}} 'cat /sys/class/dmi/id/product_uuid'

_fingerprint-linode target:
  echo "[Fort] Fingerprinting Linode VM"
  {{ssh}} root@{{target}} \
    'export TOKEN=$(curl -sX PUT -H "Metadata-Token-Expiry-Seconds: 3600" http://169.254.169.254/v1/token); \
     curl -sH "Metadata-Token: $TOKEN" http://169.254.169.254/v1/instance | grep ^id: | sed "s/id: /linode-/"'

_generate-device-keys uuid:
  #!/usr/bin/env bash
  temp=$(mktemp -d)
  install -d -m755 "$temp/persist/system/etc/ssh"
  ssh-keygen -t ed25519 \
    -N "" \
    -C "fort-device-{{uuid}}" \
    -f "$temp/persist/system/etc/ssh/ssh_host_ed25519_key"
  echo $temp

_scaffold-device-flake profile uuid keydir:
  #!/usr/bin/env bash
  echo "[Fort] Scaffolding device flake"
  mkdir -p "./devices/{{uuid}}"

  cat > "./devices/{{uuid}}/manifest.nix" <<-EOF
  {
    uuid = "{{uuid}}";
    profile = "{{profile}}";
    pubkey = ''$(cat {{keydir}}/persist/system/etc/ssh/ssh_host_ed25519_key.pub)'';
    stateVersion = ''$(nix eval --raw nixpkgs#lib.version | cut -d. -f1,2)'';
  }
  EOF

  cat > "./devices/{{uuid}}/flake.nix" <<-'EOF'
  {
    inputs = {
      root.url = "path:../../";
      nixpkgs.follows = "root/nixpkgs";
      disko.follows = "root/disko";
      impermanence.follows = "root/impermanence";
    };
  
    outputs =
      {
        self, 
        nixpkgs, 
        disko, 
        impermanence,
        ...
      }:
      import ../../common/device.nix {
        inherit self nixpkgs disko impermanence;
        deviceDir = ./.;
      };
  }
  EOF
  git add ./devices/{{uuid}}

_bootstrap-device target uuid keydir:
  echo "[Fort] Bootstrapping device"
  nix run .#nixos-anywhere -- \
    --generate-hardware-config nixos-generate-config ./devices/{{uuid}}/hardware-configuration.nix \
    --extra-files "{{keydir}}" \
    --flake ./devices/{{uuid}}#{{uuid}} \
    -i ~/.ssh/fort \
    --target-host root@{{target}}

_cleanup-device-provisioning uuid target keydir:
  echo "[Fort] Running cleanup"
  rm -rf "{{keydir}}"
  ssh-keygen -R {{target}} >/dev/null 2>&1
  git add ./devices/{{uuid}}

assign device host:
  #!/usr/bin/env bash
  echo "[Fort] Creating host {{host}} config assigned to {{device}}"
  mkdir -p "./hosts/{{host}}"

  cat > "./hosts/{{host}}/flake.nix" <<-EOF
  {
    inputs = {
      root.url = "path:../..";
      nixpkgs.follows = "root/nixpkgs";
      disko.follows = "root/disko";
      impermanence.follows = "root/impermanence";
      deploy-rs.follows = "root/deploy-rs";
      agenix.follows = "root/agenix";
    };

    outputs =
      {
        self,
        nixpkgs,
        disko,
        impermanence,
        deploy-rs,
        agenix,
        ...
      }:
      import ../../common/host.nix {
        inherit
          self
          nixpkgs
          disko
          impermanence
          deploy-rs
          agenix
          ;
        hostDir = ./.;
      };
  }
  EOF

  cat > "./hosts/{{host}}/manifest.nix" <<-EOF
  rec {
    hostName = "{{host}}";
    device = "{{device}}";

    roles = [ ];

    apps = [ ];

    aspects = [ "mesh" "observable" ];

    module =
      { config, ... }:
      {
        config.fort.host = { inherit roles apps aspects; };
      };
  }
  EOF

  git add ./hosts/{{host}}
  (cd ./hosts/{{host}} && nix flake lock)
  git add ./hosts/{{host}}

deploy host addr=(host + ".fort." + domain):
  #!/usr/bin/env bash
  trap 'git checkout -- $(git diff --name-only -- "*.age" || true)' EXIT
  KEYED_FOR_DEVICES=1 nix run .#agenix -- -i ~/.ssh/fort -r
  nix run .#deploy-rs -- -d --hostname {{addr}} --remote-build ./hosts/{{host}}#{{host}}

fmt:
  nix run .#nixfmt -- .

ssh host:
  ssh -i ~/.ssh/fort root@{{host}}

age path:
  nix run .#agenix -- -i ~/.ssh/fort -e {{path}}
