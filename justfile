deploy_key := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.settings.principals.admin.privateKeyPath'`
domain := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.settings.domain'`
cluster := `nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).clusterName'`

provision profile target user="admin":
  #!/usr/bin/env bash
  echo "[Fort] Provisioning target at {{target}}"
  if [ "{{profile}}" = "linode" ]; then
    uuid=$(just _fingerprint-linode {{target}} | tail -n1 | tr -d '\r\n')
  elif [ "{{profile}}" = "mac-mini" ]; then
    uuid=$(just _fingerprint-darwin {{target}} {{user}} | tail -n1 | tr -d '\r\n')
  else
    uuid=$(just _fingerprint-hardware {{target}} | tail -n1 | tr -d '\r\n')
  fi

  profile_manifest="./device-profiles/{{profile}}/manifest.nix"
  platform=$(nix eval --raw --impure --expr "(import ./${profile_manifest}).platform or \"nixos\"")

  if [ "$platform" = "darwin" ]; then
    just _scaffold-device-flake {{profile}} $uuid
    just _bootstrap-darwin {{target}} {{user}} $uuid
  else
    keydir=$(just _generate-device-keys $uuid | tail -n1)
    just _scaffold-device-flake {{profile}} $uuid $keydir
    just _bootstrap-device {{target}} $uuid $keydir
    just _cleanup-device-provisioning $uuid {{target}} $keydir
  fi

_fingerprint-hardware target:
  #!/usr/bin/env bash
  echo "[Fort] Fingerprinting physical hardware"
  GARBAGE_UUID="03000200-0400-0500-0006-000700080009"
  uuid=$(ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{target}} \
    'cat /sys/class/dmi/id/product_uuid' | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')
  if [[ "$uuid" == "$GARBAGE_UUID" ]]; then
    echo "[Fort] DMI product_uuid is a known placeholder, deriving from primary NIC MAC" >&2
    mac=$(ssh -i {{deploy_key}} -o StrictHostKeyChecking=no root@{{target}} \
      'ip link show $(ip route show default | awk "/default/{print \$5}" | head -1) | awk "/ether/{print \$2}"' \
      | tr -d '\r\n')
    if [[ -z "$mac" ]]; then
      echo "[Fort] ERROR: Could not determine primary NIC MAC address" >&2
      exit 1
    fi
    # UUIDv5: fort namespace (derived from fort.gisi.network) + MAC address
    uuid=$(python3 -c "import uuid; ns = uuid.uuid5(uuid.NAMESPACE_DNS, 'fort.{{domain}}'); print(uuid.uuid5(ns, '$mac'))")
  fi
  echo "$uuid"

_fingerprint-darwin target user="admin":
  echo "[Fort] Fingerprinting macOS hardware"
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no {{user}}@{{target}} 'ioreg -d2 -c IOPlatformExpertDevice | awk -F\" "/IOPlatformUUID/{print \$4}"'

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


_scaffold-device-flake profile uuid keydir="":
  #!/usr/bin/env bash
  echo "[Fort] Scaffolding device flake"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; mkdir -p "${devices_root}"; fi

  mkdir -p "${devices_root}/{{uuid}}"

  if [[ -n "{{keydir}}" ]]; then
    pubkey=$(cat {{keydir}}/persist/system/etc/ssh/ssh_host_ed25519_key.pub)
  else
    pubkey="PLACEHOLDER_SET_AFTER_BOOTSTRAP"
  fi

  cat > "${devices_root}/{{uuid}}/manifest.nix" <<-EOF
  {
    uuid = "{{uuid}}";
    profile = "{{profile}}";
    pubkey = ''${pubkey}'';
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
  #!/usr/bin/env bash
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


_bootstrap-darwin target user uuid:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "[Fort] Bootstrapping darwin host at {{target}}"

  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi

  remote="{{user}}@{{target}}"

  # Install Xcode Command Line Tools (idempotent, needed for git/build tools)
  echo "[Fort] Installing Xcode Command Line Tools"
  ssh -t -o StrictHostKeyChecking=no "$remote" \
    'if xcode-select -p >/dev/null 2>&1; then echo "CLT already installed"; else echo "Installing CLT (this may take a few minutes)..." && sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress && CLT_LABEL=$(softwareupdate -l 2>&1 | grep "Label: Command Line" | awk -F"Label: " "{print \$2}" | head -1) && echo "Found: $CLT_LABEL" && sudo softwareupdate -i "$CLT_LABEL" --agree-to-license && sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress; fi'

  # Install Nix via Determinate package for macOS (idempotent, needs sudo → -t for TTY)
  echo "[Fort] Installing Nix"
  ssh -t -o StrictHostKeyChecking=no "$remote" \
    'if command -v nix >/dev/null 2>&1; then echo "Nix already installed"; else curl --proto "=https" --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --determinate --no-confirm; fi'

  # Bootstrap nix-darwin (idempotent, activation requires root)
  # Creates a minimal flake at /etc/nix-darwin, then runs darwin-rebuild switch
  echo "[Fort] Bootstrapping nix-darwin"
  ssh -t -o StrictHostKeyChecking=no "$remote" \
    'if command -v darwin-rebuild >/dev/null 2>&1; then echo "nix-darwin already installed"; else sudo rm -rf /etc/nix-darwin && sudo mkdir -p /etc/nix-darwin && sudo chown $(whoami) /etc/nix-darwin && cd /etc/nix-darwin && nix flake init -t nix-darwin/master && sed -i "" "s/simple/$(scutil --get LocalHostName)/" flake.nix && sed -i "" "/nixpkgs.hostPlatform/a\\
      nix.enable = false;" flake.nix && for f in /etc/zshenv /etc/bashrc /etc/zshrc; do [ -f "$f" ] && ! [ -L "$f" ] && sudo mv "$f" "$f.before-nix-darwin"; done && sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake /etc/nix-darwin; fi'

  # Set up fort directory and clone repo
  echo "[Fort] Setting up /var/lib/fort-nix"
  ssh -t -o StrictHostKeyChecking=no "$remote" \
    'sudo mkdir -p /var/lib/fort /var/lib/fort-nix && sudo chown $(whoami) /var/lib/fort-nix'

  # Clone needs auth — use local deploy token to construct authenticated URL
  deploy_token=""
  for tf in /var/lib/fort-git/dev-token /var/lib/fort-git/deploy-token; do
    if [ -f "$tf" ]; then deploy_token=$(cat "$tf"); break; fi
  done
  if [ -z "$deploy_token" ]; then
    echo "[Fort] WARNING: No forge token found — clone may fail if repo requires auth"
    clone_url="https://git.{{domain}}/$(nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.forge.org')/$(nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.forge.repo').git"
  else
    clone_url="https://fort-deploy:${deploy_token}@git.{{domain}}/$(nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.forge.org')/$(nix eval --raw --impure --expr '(import ./common/cluster-context.nix { }).manifest.fortConfig.forge.repo').git"
  fi

  ssh -o StrictHostKeyChecking=no "$remote" \
    "if [ -d /var/lib/fort-nix/.git ]; then echo 'Repo already cloned'; else git clone --branch main '${clone_url}' /var/lib/fort-nix; fi"

  # Grab the host's SSH public key and update the device manifest
  echo "[Fort] Capturing host SSH public key"
  pubkey=$(ssh -o StrictHostKeyChecking=no "$remote" 'cat /etc/ssh/ssh_host_ed25519_key.pub' | tr -d '\r\n')

  device_manifest="${devices_root}/{{uuid}}/manifest.nix"
  sed -i "s|PLACEHOLDER_SET_AFTER_BOOTSTRAP|${pubkey}|" "$device_manifest"
  git add "$device_manifest"

  echo "[Fort] Darwin bootstrap complete"
  echo "  Next steps:"
  echo "  1. just assign {{uuid}} <hostname>"
  echo "  2. Commit and push to main"
  echo "  3. SSH in and run: cd /var/lib/fort-nix && sudo darwin-rebuild switch --flake ./clusters/{{cluster}}/hosts/<hostname>"

_cleanup-device-provisioning uuid target keydir:
  #!/usr/bin/env bash
  echo "[Fort] Running cleanup"
  rm -rf "{{keydir}}"
  ssh-keygen -R {{target}} >/dev/null 2>&1
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi
  git add "${devices_root}/{{uuid}}"

assign device host:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "[Fort] Creating host {{host}} config assigned to {{device}}"
  hosts_root="./hosts"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then
    hosts_root="./clusters/{{cluster}}/hosts"
    devices_root="./clusters/{{cluster}}/devices"
    mkdir -p "${hosts_root}"
  fi

  # Detect platform from device manifest
  device_manifest="${devices_root}/{{device}}/manifest.nix"
  if [[ ! -f "$device_manifest" ]]; then
    echo "[Fort] ERROR: Device manifest not found: $device_manifest" >&2
    echo "  Run 'just provision <profile> <target>' first." >&2
    exit 1
  fi
  profile=$(nix eval --raw --impure --expr "(import ./${device_manifest}).profile")
  profile_manifest="./device-profiles/${profile}/manifest.nix"
  platform=$(nix eval --raw --impure --expr "(import ./${profile_manifest}).platform or \"nixos\"")

  mkdir -p "${hosts_root}/{{host}}"

  if [[ "$platform" == "darwin" ]]; then
    cat > "${hosts_root}/{{host}}/flake.nix" <<-'EOF'
  {
    inputs = {
      cluster.url = "path:../..";
      nixpkgs.follows = "cluster/nixpkgs";
      sops-nix.follows = "cluster/sops-nix";
      nix-darwin.follows = "cluster/nix-darwin";
    };

    outputs =
      {
        self,
        nixpkgs,
        sops-nix,
        nix-darwin,
        ...
      }:
      import ../../../../common/host.nix {
        inherit
          self
          nixpkgs
          sops-nix
          nix-darwin
          ;
        hostDir = ./.;
      };
  }
  EOF
  else
    cat > "${hosts_root}/{{host}}/flake.nix" <<-'EOF'
  {
    inputs = {
      cluster.url = "path:../..";
      nixpkgs.follows = "cluster/nixpkgs";
      disko.follows = "cluster/disko";
      impermanence.follows = "cluster/impermanence";
      deploy-rs.follows = "cluster/deploy-rs";
      sops-nix.follows = "cluster/sops-nix";
    };

    outputs =
      {
        self,
        nixpkgs,
        disko,
        impermanence,
        deploy-rs,
        sops-nix,
        ...
      }:
      import ../../../../common/host.nix {
        inherit
          self
          nixpkgs
          disko
          impermanence
          deploy-rs
          sops-nix
          ;
        hostDir = ./.;
      };
  }
  EOF
  fi

  cat > "${hosts_root}/{{host}}/manifest.nix" <<-EOF
  rec {
    hostName = "{{host}}";
    device = "{{device}}";

    roles = [ ];

    apps = [ ];

    aspects = [ "observable" ];

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

  hosts_root="./hosts"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; devices_root="./clusters/{{cluster}}/devices"; fi

  # Detect platform
  host_manifest_rel="${hosts_root#./}/{{host}}/manifest.nix"
  device_uuid=$(nix eval --raw --impure --expr "(import ./${host_manifest_rel}).device")
  device_manifest_rel="${devices_root#./}/${device_uuid}/manifest.nix"
  device_profile=$(nix eval --raw --impure --expr "(import ./${device_manifest_rel}).profile" 2>/dev/null || echo "")
  device_platform=$(nix eval --raw --impure --expr "(import ./device-profiles/${device_profile}/manifest.nix).platform or \"nixos\"" 2>/dev/null || echo "nixos")

  # Expand ~ in deploy key path
  deploy_key_expanded="{{deploy_key}}"
  deploy_key_expanded="${deploy_key_expanded/#\~/$HOME}"

  # Check if master key exists - determines deploy mode
  if [[ -f "$deploy_key_expanded" ]]; then
    if [[ "$device_platform" == "darwin" ]]; then
      just _deploy-direct-darwin {{host}} {{addr}}
    else
      just _deploy-direct {{host}} {{addr}}
    fi
  else
    just _deploy-gitops {{host}} {{addr}}
  fi

# Verify deployment target matches expected device UUID
_verify-deploy-target host addr:
  #!/usr/bin/env bash
  set -euo pipefail

  hosts_root="./hosts"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; devices_root="./clusters/{{cluster}}/devices"; fi

  host_dir="${hosts_root}/{{host}}"
  host_manifest_rel="${host_dir#./}/manifest.nix"
  expected_uuid=$(nix eval --raw --impure --expr "(import ./${host_manifest_rel}).device")

  device_manifest_rel="${devices_root#./}/${expected_uuid}/manifest.nix"
  device_profile=$(nix eval --raw --impure --expr "(import ./${device_manifest_rel}).profile" 2>/dev/null || echo "")

  echo "[Fort] Verifying {{host}} deployment target ({{addr}}) matches device ${expected_uuid}"

  device_platform=$(nix eval --raw --impure --expr "(import ./device-profiles/${device_profile}/manifest.nix).platform or \"nixos\"" 2>/dev/null || echo "nixos")

  if [[ "$device_profile" == "linode" ]]; then
    actual_uuid=$(just _fingerprint-linode {{addr}} | tail -n1 | tr -d '\r\n')
  elif [[ "$device_platform" == "darwin" ]]; then
    actual_uuid=$(just _fingerprint-darwin {{addr}} | tail -n1 | tr -d '\r\n')
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

# Direct deploy via deploy-rs (requires master key)
_deploy-direct host addr:
  #!/usr/bin/env bash
  just _verify-deploy-target {{host}} {{addr}}

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi
  host_dir="${hosts_root}/{{host}}"

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

# Direct deploy for darwin hosts (SSH + git pull + darwin-rebuild)
_deploy-direct-darwin host addr:
  #!/usr/bin/env bash
  set -euo pipefail

  just _verify-deploy-target {{host}} {{addr}}

  # Push to main so the remote has latest
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  echo "[Fort] Pushing ${current_branch} to main"
  git push origin "${current_branch}:main"

  deploy_commit=$(git rev-parse --short HEAD)
  deploy_timestamp=$(date -Iseconds)
  deploy_branch="${current_branch}"
  deploy_info="{\"commit\":\"${deploy_commit}\",\"timestamp\":\"${deploy_timestamp}\",\"branch\":\"${deploy_branch}\"}"

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi

  echo "[Fort] Deploying {{host}} via SSH (git pull + darwin-rebuild)"
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no admin@{{addr}} \
    "set -euo pipefail && cd /var/lib/fort-nix && git fetch origin main && git checkout main && git reset --hard origin/main && sudo darwin-rebuild switch --flake ./${hosts_root#./}/{{host}} && sudo mkdir -p /var/lib/fort && echo '${deploy_info}' | sudo tee /var/lib/fort/deploy-info.json > /dev/null && echo '[Fort] {{host}} deployed ${deploy_commit} successfully'"

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
              echo "[Fort] Waiting for gitops to fetch... (has ${pending:-unknown})"
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

rekey path="":
  #!/usr/bin/env bash
  nix-shell -p sops ssh-to-age jq --run "bash scripts/rekey.sh '{{path}}'"

fmt:
  nix run .#nixfmt -- .

ssh host:
  #!/usr/bin/env bash
  hosts_root="./hosts"
  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; devices_root="./clusters/{{cluster}}/devices"; fi

  host_manifest_rel="${hosts_root#./}/{{host}}/manifest.nix"
  device_uuid=$(nix eval --raw --impure --expr "(import ./${host_manifest_rel}).device" 2>/dev/null || echo "")
  ssh_user="root"
  if [[ -n "$device_uuid" ]]; then
    device_manifest_rel="${devices_root#./}/${device_uuid}/manifest.nix"
    device_profile=$(nix eval --raw --impure --expr "(import ./${device_manifest_rel}).profile" 2>/dev/null || echo "")
    device_platform=$(nix eval --raw --impure --expr "(import ./device-profiles/${device_profile}/manifest.nix).platform or \"nixos\"" 2>/dev/null || echo "nixos")
    if [[ "$device_platform" == "darwin" ]]; then ssh_user="admin"; fi
  fi
  ssh -i {{deploy_key}} -o StrictHostKeyChecking=no "${ssh_user}@{{host}}"

edit-secret path:
  sops {{path}}

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

  export NIX_CONFIG=$'warn-dirty = false\n'

  hosts_root="./hosts"
  if [[ -n "{{cluster}}" ]]; then hosts_root="./clusters/{{cluster}}/hosts"; fi

  # Single host mode
  if [[ -n "{{host}}" ]]; then
    echo "[Fort] nix flake check ${hosts_root}/{{host}}"
    nix flake check "${hosts_root}/{{host}}"
    exit 0
  fi

  # Full validation — all flake checks in parallel
  fail=0
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  nix flake check . > "$tmpdir/root.log" 2>&1 &

  for host in "${hosts_root}"/*; do
    [[ -d "${host}" ]] || continue
    name=$(basename "$host")
    nix flake check "${host}" > "$tmpdir/host-${name}.log" 2>&1 &
  done

  devices_root="./devices"
  if [[ -n "{{cluster}}" ]]; then devices_root="./clusters/{{cluster}}/devices"; fi
  for device in "${devices_root}"/*; do
    [[ -d "${device}" ]] || continue
    name=$(basename "$device")
    nix flake check "${device}" > "$tmpdir/device-${name}.log" 2>&1 &
  done

  for job in $(jobs -p); do
    if ! wait "$job"; then fail=1; fi
  done

  # Print results
  echo "[Fort] nix flake check ."
  cat "$tmpdir/root.log"
  for host in "${hosts_root}"/*; do
    [[ -d "${host}" ]] || continue
    name=$(basename "$host")
    echo "[Fort] nix flake check ${host}"
    cat "$tmpdir/host-${name}.log"
  done
  for device in "${devices_root}"/*; do
    [[ -d "${device}" ]] || continue
    name=$(basename "$device")
    echo "[Fort] nix flake check ${device}"
    cat "$tmpdir/device-${name}.log"
  done

  if [[ "$fail" -ne 0 ]]; then
    echo "[Fort] Flake checks failed"
    exit 1
  fi

  # Run Go tests for provider directories
  for provider_dir in ./apps/*/provider ./aspects/*/provider; do
    if [[ -d "$provider_dir" ]] && [[ -f "$provider_dir/go.mod" ]]; then
      echo "[Fort] go test ${provider_dir}"
      (cd "$provider_dir" && go test -v ./...)
    fi
  done
