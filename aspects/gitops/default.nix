{
  rootManifest,
  hostManifest,
  deviceProfileManifest,
  cluster,
  # If true, deployments require manual confirmation via agent API
  manualDeploy ? false,
  ...
}:
{ config, lib, pkgs, ... }:
let
  platform = deviceProfileManifest.platform or "nixos";
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;

  credDir = "/var/lib/fort-git";
  tokenFile = "${credDir}/deploy-token";
  repoUrl = "https://git.${domain}/${forgeConfig.org}/${forgeConfig.repo}.git";

  # Gitops state
  stateDir = "/var/lib/fort-gitops";
  repoDir = "${stateDir}/repository";
  flakeSubdir = "clusters/${cluster.clusterName}/hosts/${hostManifest.hostName}";

  # Cache configuration (delivered via control plane)
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";
  cacheDir = "/var/lib/fort/nix";
  cacheConfFile = "${cacheDir}/attic-cache.conf";
  pushTokenFile = "${cacheDir}/attic-push-token";

  # Git credential helper — called by git with "get" argument
  gitCredHelper = pkgs.writeShellScript "fort-git-cred-helper" ''
    if [ "$1" = "get" ] && [ -s "${tokenFile}" ]; then
      echo "username=token"
      echo "password=$(${pkgs.coreutils}/bin/cat ${tokenFile})"
    fi
  '';

  # Handler for git-token: extracts token from JSON response and stores it
  gitTokenHandler = pkgs.writeShellScript "git-token-handler" ''
    ${pkgs.coreutils}/bin/mkdir -p "${credDir}"
    ${pkgs.jq}/bin/jq -r '.token' > "${tokenFile}"
    ${pkgs.coreutils}/bin/chmod 600 "${tokenFile}"
  '';

  # Handler for attic-token: stores cache config and push token
  atticTokenHandler = pkgs.writeShellScript "attic-token-handler" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir -p "${cacheDir}"
    payload=$(${pkgs.coreutils}/bin/cat)
    respCacheUrl=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.cacheUrl')
    respCacheName=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.cacheName')
    publicKey=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.publicKey')
    pushToken=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.pushToken')
    ${pkgs.coreutils}/bin/cat > "${cacheConfFile}" <<EOF
extra-substituters = $respCacheUrl/$respCacheName
extra-trusted-public-keys = $publicKey
EOF
    ${pkgs.coreutils}/bin/chmod 644 "${cacheConfFile}"
    echo "$pushToken" > "${pushTokenFile}"
    ${pkgs.coreutils}/bin/chmod 600 "${pushTokenFile}"
  '';

  # Post-deploy: push built system to attic cache
  postDeployScript = pkgs.writeShellScript "fort-gitops-post-deploy" ''
    set -euf
    export PATH="${lib.makeBinPath [ pkgs.attic-client pkgs.coreutils pkgs.util-linux ]}:$PATH"
    log() { logger -t fort-gitops-cache "$@"; }
    if [ ! -s "${pushTokenFile}" ]; then
      log "Cache push token not available, skipping"
      exit 0
    fi
    SYSTEM_PATH=$(readlink -f /nix/var/nix/profiles/system)
    export HOME=$(mktemp -d)
    trap 'rm -rf "$HOME"' EXIT
    mkdir -p "$HOME/.config/attic"
    cat > "$HOME/.config/attic/config.toml" <<EOF
default-server = "local"

[servers.local]
endpoint = "${cacheUrl}"
token = "$(cat ${pushTokenFile})"
EOF
    log "Pushing $SYSTEM_PATH to cache"
    if attic push ${cacheName} "$SYSTEM_PATH" 2>&1 | logger -t fort-gitops-cache; then
      log "Cache push complete"
    else
      log "Cache push failed (non-fatal)"
    fi
  '';

  # --- Main gitops polling script ---
  gitopsScript = pkgs.writeShellScript "fort-gitops" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.nix pkgs.coreutils pkgs.jq ]}:/run/current-system/sw/bin:$PATH"

    log() { logger -t fort-gitops "$@"; }

    # Clone if missing
    if [ ! -d "${repoDir}/.git" ]; then
      if [ ! -s "${tokenFile}" ]; then
        exit 0  # No token yet, wait for control plane delivery
      fi
      log "Cloning ${repoUrl}"
      git -c credential.helper=${gitCredHelper} clone --branch main "${repoUrl}" "${repoDir}"
    fi

    cd "${repoDir}"

    # Fetch latest
    if ! git -c credential.helper=${gitCredHelper} fetch origin main 2>&1 | logger -t fort-gitops-fetch; then
      log "Fetch failed, will retry"
      exit 0
    fi

    DEPLOYED=$(cat "${stateDir}/deployed-commit" 2>/dev/null || echo "none")
    REMOTE=$(git rev-parse origin/main)

    if [ "$DEPLOYED" = "$REMOTE" ]; then
      exit 0
    fi

    log "New commit: ''${REMOTE:0:8} (deployed: ''${DEPLOYED:0:8})"
    git reset --hard origin/main

    ${if manualDeploy then ''
    # Manual mode: build only, wait for confirmation via deploy capability
    log "Building (manual confirmation required)..."
    if nixos-rebuild build --flake "./${flakeSubdir}" 2>&1 | logger -t fort-gitops-build; then
      echo "$REMOTE" > "${stateDir}/pending-commit"
      log "Build ready: ''${REMOTE:0:8} (awaiting confirmation)"
    else
      log "Build failed for ''${REMOTE:0:8}"
    fi
    '' else ''
    # Auto mode: build and switch
    log "Building and switching..."
    if nixos-rebuild switch --flake "./${flakeSubdir}" 2>&1 | logger -t fort-gitops-build; then
      echo "$REMOTE" > "${stateDir}/deployed-commit"
      rm -f "${stateDir}/pending-commit"
      log "Deployed: ''${REMOTE:0:8}"
      ${postDeployScript} || log "Post-deploy hook failed (non-fatal)"
    else
      log "Build/switch failed for ''${REMOTE:0:8}"
    fi
    ''}
  '';

  # --- Deploy handler for manual confirmation ---
  deployHandler = pkgs.writeShellScript "fort-gitops-deploy" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.nix pkgs.coreutils pkgs.jq ]}:/run/current-system/sw/bin:$PATH"

    log() { logger -t fort-gitops-deploy "$@"; }

    REQUEST=$(cat)
    REQ_SHA=$(echo "$REQUEST" | jq -r '.sha // empty')

    if [ -z "$REQ_SHA" ]; then
      echo '{"error":"missing sha parameter"}'
      exit 0
    fi

    PENDING=$(cat "${stateDir}/pending-commit" 2>/dev/null || echo "")

    if [ -z "$PENDING" ]; then
      DEPLOYED=$(cat "${stateDir}/deployed-commit" 2>/dev/null || echo "")
      if [ -n "$DEPLOYED" ] && [[ "$DEPLOYED" == "$REQ_SHA"* ]]; then
        echo "{\"status\":\"already_deployed\",\"sha\":\"$DEPLOYED\"}"
      else
        echo '{"status":"no_pending_build","note":"no build waiting for confirmation"}'
      fi
      exit 0
    fi

    # Verify SHA matches (prefix matching supported)
    if [[ "$PENDING" != "$REQ_SHA"* ]]; then
      echo "{\"status\":\"sha_mismatch\",\"expected\":\"$PENDING\",\"provided\":\"$REQ_SHA\"}"
      exit 0
    fi

    log "Deploying ''${PENDING:0:8} (confirmed by $REQ_SHA)"
    cd "${repoDir}"

    if nixos-rebuild switch --flake "./${flakeSubdir}" 2>&1 | logger -t fort-gitops-deploy; then
      echo "$PENDING" > "${stateDir}/deployed-commit"
      rm -f "${stateDir}/pending-commit"
      log "Deployed: ''${PENDING:0:8}"
      ${postDeployScript} || log "Post-deploy hook failed (non-fatal)"
      echo "{\"status\":\"deployed\",\"sha\":\"$PENDING\"}"
    else
      echo '{"status":"deploy_failed","error":"nixos-rebuild switch failed"}'
    fi
  '';

  # --- Darwin gitops-lite: launchd-based git pull + darwin-rebuild ---
  darwinRepoDir = "/var/lib/fort-nix";
  darwinRebuildScript = pkgs.writeShellScript "fort-gitops-rebuild" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.nix pkgs.coreutils ]}:$PATH"

    log() { /usr/bin/logger -t fort-gitops "$@"; echo "$@"; }

    if [ ! -d "${darwinRepoDir}/.git" ]; then
      log "Cloning ${repoUrl} into ${darwinRepoDir}"
      git clone --branch main "${repoUrl}" "${darwinRepoDir}"
    fi

    cd "${darwinRepoDir}"

    if [ -f "${tokenFile}" ]; then
      git config credential.helper "!f() { echo password=$(cat ${tokenFile}); }; f"
    fi

    git fetch origin main 2>/dev/null
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/main)

    if [ "$LOCAL" = "$REMOTE" ]; then
      log "Up to date at $LOCAL"
      exit 0
    fi

    log "Updating $LOCAL -> $REMOTE"
    git reset --hard origin/main

    log "Running darwin-rebuild switch"
    if darwin-rebuild switch --flake "./${flakeSubdir}" 2>&1; then
      log "Rebuild succeeded at $REMOTE"
    else
      log "Rebuild failed at $REMOTE"
      exit 1
    fi
  '';
in
if platform == "darwin" then
{
  launchd.daemons.fort-gitops = {
    serviceConfig = {
      Label = "network.gisi.fort.gitops";
      ProgramArguments = [ "${darwinRebuildScript}" ];
      StartInterval = 300;
      StandardOutPath = "/var/log/fort-gitops.log";
      StandardErrorPath = "/var/log/fort-gitops.log";
    };
  };

  environment.systemPackages = [ pkgs.git ];
}
else
{
  # Ensure directories exist
  # Note: credDir is 0755 so dev-sandbox credential helper can read token files
  systemd.tmpfiles.rules = [
    "d ${credDir} 0755 root root -"
    "d ${cacheDir} 0755 root root -"
    "d ${stateDir} 0755 root root -"
  ];

  # Request RO git token from forge for pulls
  fort.host.needs.git-token.default = {
    from = "drhorrible";
    request = { access = "ro"; };
    handler = gitTokenHandler;
  };

  # Request attic cache config and push token from forge
  fort.host.needs.attic-token.default = {
    from = "drhorrible";
    request = { };
    handler = atticTokenHandler;
  };

  # Poll every 30s, 30s after boot
  systemd.timers.fort-gitops = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
    };
  };

  systemd.services.fort-gitops = {
    description = "Fort GitOps - pull and deploy from git";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gitopsScript}";
    };
  };

  # Deploy capability for manual confirmation hosts
  fort.host.capabilities.deploy = {
    handler = "${deployHandler}";
    mode = "rpc";
    description = "Trigger deployment after verifying expected SHA";
    allowed = [ "dev-sandbox" ];
  };

  environment.systemPackages = [ pkgs.git ];
}
