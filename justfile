deploy_key := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.settings.principals.admin.privateKeyPath'`
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
      cluster.url = "path:../..";
      nixpkgs.follows = "cluster/nixpkgs";
      disko.follows = "cluster/disko";
      impermanence.follows = "cluster/impermanence";
    };

    outputs =
      {
        self,
        nixpkgs,
        disko,
        impermanence,
        ...
      }:
      import ../../../../common/device.nix {
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
      cluster.url = "path:../..";
      nixpkgs.follows = "cluster/nixpkgs";
      disko.follows = "cluster/disko";
      impermanence.follows = "cluster/impermanence";
      deploy-rs.follows = "cluster/deploy-rs";
      agenix.follows = "cluster/agenix";
      comin.follows = "cluster/comin";
    };

    outputs =
      {
        self,
        nixpkgs,
        disko,
        impermanence,
        deploy-rs,
        agenix,
        comin,
        ...
      }:
      import ../../../../common/host.nix {
        inherit
          self
          nixpkgs
          disko
          impermanence
          deploy-rs
          agenix
          comin
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
  set -euo pipefail

  # Expand ~ in deploy key path
  deploy_key_expanded="{{deploy_key}}"
  deploy_key_expanded="${deploy_key_expanded/#\~/$HOME}"

  # Check if master key exists - determines deploy mode
  if [[ -f "$deploy_key_expanded" ]]; then
    just _deploy-direct {{host}} {{addr}}
  else
    just _deploy-gitops {{host}} {{addr}}
  fi

# Direct deploy via deploy-rs (requires master key)
_deploy-direct host addr:
  #!/usr/bin/env bash
  if [[ -n "$(git diff --name-only -- '*.age')" ]]; then
    echo "[Fort] ERROR: Uncommitted .age file changes detected. Commit or stash before deploying." >&2
    exit 1
  fi

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

  # Write deploy info for non-gitops hosts (status endpoint uses this as fallback)
  deploy_commit=$(git rev-parse --short HEAD)
  deploy_timestamp=$(date -Iseconds)
  deploy_branch=$(git rev-parse --abbrev-ref HEAD)
  deploy_info="{\"commit\":\"${deploy_commit}\",\"timestamp\":\"${deploy_timestamp}\",\"branch\":\"${deploy_branch}\"}"

  nix run .#deploy-rs -- -d --hostname {{addr}} --remote-build "${host_dir}#{{host}}"

  # Write deploy info to target host after successful deploy
  echo "[Fort] Writing deploy info to {{addr}}"
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{addr}} \
    "mkdir -p /var/lib/fort && echo '${deploy_info}' > /var/lib/fort/deploy-info.json"

# GitOps deploy via fort CLI (no master key needed)
_deploy-gitops host addr:
  #!/usr/bin/env bash
  set -euo pipefail

  target_sha=$(git rev-parse --short HEAD)
  echo "[Fort] GitOps deploy {{host}} -> ${target_sha}"

  max_attempts=90  # 7.5 minutes at 5s intervals
  attempt=0
  last_state=""

  # For manual-confirm hosts, keep calling deploy until target SHA is active
  # For auto-deploy hosts (no deploy capability), just poll status
  has_deploy_capability=true

  while true; do
    ((attempt++)) || true
    if [[ $attempt -gt $max_attempts ]]; then
      echo "[Fort] ERROR: Timed out waiting for {{host}} to deploy ${target_sha}" >&2
      exit 1
    fi

    # Check current status first
    if status_json=$(fort {{host}} status 2>/dev/null | jq -r '.body'); then
      current=$(echo "$status_json" | jq -r '.deploy.commit // empty')

      # Already deployed?
      if [[ "$current" == "$target_sha"* ]] || [[ "$target_sha" == "$current"* ]]; then
        echo "[Fort] {{host}} deployed ${target_sha} successfully"
        exit 0
      fi
    else
      if [[ "$last_state" != "unreachable" ]]; then
        echo "[Fort] Waiting for {{host}} to become reachable..."
        last_state="unreachable"
      fi
      sleep 5
      continue
    fi

    # Keep trying deploy capability until we reach target SHA
    # (Even after "deployed" response, the wrong generation might have been confirmed)
    if [[ "$has_deploy_capability" == "true" ]]; then
      if deploy_response=$(fort {{host}} deploy "{\"sha\": \"${target_sha}\"}" 2>&1); then
        deploy_body=$(echo "$deploy_response" | jq -r '.body')
        deploy_status=$(echo "$deploy_body" | jq -r '.status // .error // empty')

        case "$deploy_status" in
          deployed|confirmed)
            if [[ "$last_state" != "switching" ]]; then
              echo "[Fort] Waiting for switch..."
              last_state="switching"
            fi
            ;;
          sha_mismatch)
            if [[ "$last_state" != "fetching" ]]; then
              pending=$(echo "$deploy_body" | jq -r '.pending // empty')
              echo "[Fort] Waiting for comin to fetch... (comin has ${pending:-unknown})"
              last_state="fetching"
            fi
            ;;
          building)
            if [[ "$last_state" != "building" ]]; then
              echo "[Fort] Waiting for build..."
              last_state="building"
            fi
            ;;
          *)
            if [[ "$last_state" != "$deploy_status" ]]; then
              echo "[Fort] Deploy status: ${deploy_status}"
              last_state="$deploy_status"
            fi
            ;;
        esac
        sleep 5
      else
        # Check if it's a 404 (no deploy capability) vs other error
        if echo "$deploy_response" | grep -q "404\|not found\|unknown capability"; then
          echo "[Fort] No deploy capability, polling status..."
          has_deploy_capability=false
        else
          if [[ "$last_state" != "retrying" ]]; then
            echo "[Fort] Deploy call failed, retrying..."
            last_state="retrying"
          fi
          sleep 5
        fi
      fi
    else
      # No deploy capability - just poll status
      if [[ "$last_state" != "polling" ]]; then
        echo "[Fort] Waiting for activation... (current: ${current:-unknown})"
        last_state="polling"
      fi
      sleep 5
    fi
  done

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

test host="":
  #!/usr/bin/env bash
  set -euo pipefail

  run_flake_check() {
    local target="$1"
    echo "[Fort] nix flake check ${target}"
    NIX_CONFIG=$'warn-dirty = false\n' nix flake check "${target}"
  }

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi

  # Single host mode
  if [[ -n "{{host}}" ]]; then
    run_flake_check "${hosts_root}/{{host}}"
    exit 0
  fi

  # Full validation
  run_flake_check "."

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
