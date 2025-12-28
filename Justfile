deploy_key := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.settings.sshKey.privateKeyPath'`
domain := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.settings.domain'`
cluster := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).clusterName'`

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
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{target}} 'cat /sys/class/dmi/id/product_uuid'

_fingerprint-linode target:
  echo "[Fort] Fingerprinting Linode VM"
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{target}} \
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
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; mkdir -p "${devices_root}"; fi

  mkdir -p "${devices_root}/{{uuid}}"

  cat > "${devices_root}/{{uuid}}/manifest.nix" <<-EOF
  {
    uuid = "{{uuid}}";
    profile = "{{profile}}";
    pubkey = ''$(cat {{keydir}}/persist/system/etc/ssh/ssh_host_ed25519_key.pub)'';
    stateVersion = ''$(nix eval --raw nixpkgs#lib.version | cut -d. -f1,2)'';
  }
  EOF

  cat > "${devices_root}/{{uuid}}/flake.nix" <<-'EOF'
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
  git add "${devices_root}/{{uuid}}"


_bootstrap-device target uuid keydir:
  echo "[Fort] Bootstrapping device"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi

  device_dir="${devices_root}/{{uuid}}"
  nix run .#nixos-anywhere -- \
    --generate-hardware-config nixos-generate-config "${device_dir}/hardware-configuration.nix" \
    --extra-files "{{keydir}}" \
    --flake "${device_dir}#{{uuid}}" \
    -i {{deploy_key}} \
    --target-host root@{{target}}


_cleanup-device-provisioning uuid target keydir:
  echo "[Fort] Running cleanup"
  rm -rf "{{keydir}}"
  ssh-keygen -R {{target}} >/dev/null 2>&1
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi
  git add "${devices_root}/{{uuid}}"

assign device host:
  #!/usr/bin/env bash
  echo "[Fort] Creating host {{host}} config assigned to {{device}}"
  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; mkdir -p "${hosts_root}"; fi

  mkdir -p "${hosts_root}/{{host}}"

  cat > "${hosts_root}/{{host}}/flake.nix" <<-EOF
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

  cat > "${hosts_root}/{{host}}/manifest.nix" <<-EOF
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

  git add "${hosts_root}/{{host}}"
  (cd "${hosts_root}/{{host}}" && nix flake lock)
  git add "${hosts_root}/{{host}}"

deploy host addr=(host + ".fort." + domain):
  #!/usr/bin/env bash
  hosts_root="./hosts"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; devices_root="./clusters/{{cluster}}/devices"; fi

  host_dir="${hosts_root}/{{host}}"
  host_manifest_rel="${host_dir#./}/manifest.nix"
  expected_uuid=$(nix eval --raw --impure --expr "(import ./${host_manifest_rel}).device")

  device_manifest_rel="${devices_root#./}/${expected_uuid}/manifest.nix"
  device_profile=$(nix eval --raw --impure --expr "(import ./${device_manifest_rel}).profile" 2>/dev/null || echo "")

  echo "[Fort] Verifying {{host}} deployment target ({{addr}}) matches device ${expected_uuid}"

  if [[ "$device_profile" == "linode" ]]; then
    actual_uuid=$(just _fingerprint-linode {{addr}} | tail -n1 | tr -d '\r\n')
  else
    actual_uuid=$(just _fingerprint-hardware {{addr}} | tail -n1 | tr -d '\r\n')
  fi

  if [[ -z "$actual_uuid" ]]; then
    echo "[Fort] ERROR: Unable to fingerprint deployment target {{addr}}" >&2
    exit 1
  fi

  if [[ "$actual_uuid" != "$expected_uuid" ]]; then
    echo "[Fort] ERROR: Target {{addr}} reports device UUID ${actual_uuid}, expected ${expected_uuid}" >&2
    exit 1
  fi

  trap 'git checkout -- $(git diff --name-only -- "*.age" || true)' EXIT
  KEYED_FOR_DEVICES=1 nix run .#agenix -- -i {{deploy_key}} -r
  nix run .#deploy-rs -- -d --hostname {{addr}} --remote-build "${host_dir}#{{host}}"

fmt:
  nix run .#nixfmt -- .

ssh host:
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{host}}

age path:
  nix run .#agenix -- -i {{deploy_key}} -e {{path}}

sync-services:
  #!/usr/bin/env bash
  set -euo pipefail

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi

  # Find the host with forge role
  forge_host=""
  for host_dir in "${hosts_root}"/*; do
    [[ -d "${host_dir}" ]] || continue
    manifest="${host_dir}/manifest.nix"
    [[ -f "${manifest}" ]] || continue
    if grep -q '"forge"' "${manifest}"; then
      forge_host=$(basename "${host_dir}")
      break
    fi
  done

  if [[ -z "${forge_host}" ]]; then
    echo "[Fort] ERROR: No host with forge role found" >&2
    exit 1
  fi

  echo "[Fort] Triggering service-registry on ${forge_host}"
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no "root@${forge_host}.fort.{{domain}}" \
    'systemctl start fort-service-registry.service && journalctl -u fort-service-registry.service -n 50 --no-pager'

test:
  #!/usr/bin/env bash
  set -euo pipefail

  run_flake_check() {
    local target="$1"
    echo "[Fort] nix flake check ${target}"
    NIX_CONFIG=$'warn-dirty = false\n' nix flake check "${target}"
  }

  run_flake_check "."

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi
  for host in "${hosts_root}"/*; do
    [[ -d "${host}" ]] || continue
    run_flake_check "${host}"
  done

  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi
  for device in "${devices_root}"/*; do
    [[ -d "${device}" ]] || continue
    run_flake_check "${device}"
  done
