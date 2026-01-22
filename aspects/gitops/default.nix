{
  rootManifest,
  hostManifest,
  cluster,
  # If true, deployments require manual confirmation via agent API
  manualDeploy ? false,
  ...
}:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;
  credDir = "/var/lib/fort-git";
  tokenFile = "${credDir}/deploy-token";

  repoUrl = "https://git.${domain}/${forgeConfig.org}/${forgeConfig.repo}.git";

  # Cache configuration (delivered via control plane)
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";
  cacheDir = "/var/lib/fort/nix";
  cacheConfFile = "${cacheDir}/attic-cache.conf";
  pushTokenFile = "${cacheDir}/attic-push-token";

  # Comin binary for CLI commands
  cominBin = config.services.comin.package;

  # Go handler for deploy capability
  deployProvider = import ./provider {
    inherit pkgs;
    cominPath = "${cominBin}/bin/comin";
  };

  # Handler for git-token: extracts token from JSON response and stores it
  gitTokenHandler = pkgs.writeShellScript "git-token-handler" ''
    ${pkgs.coreutils}/bin/mkdir -p "${credDir}"
    ${pkgs.jq}/bin/jq -r '.token' > "${tokenFile}"
    ${pkgs.coreutils}/bin/chmod 600 "${tokenFile}"
    # Restart comin to pick up new credentials
    ${pkgs.systemd}/bin/systemctl restart comin
  '';

  # Handler for attic-token: stores cache config and push token
  atticTokenHandler = pkgs.writeShellScript "attic-token-handler" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/mkdir -p "${cacheDir}"

    # Read payload from stdin
    payload=$(${pkgs.coreutils}/bin/cat)

    # Extract fields from response
    respCacheUrl=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.cacheUrl')
    respCacheName=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.cacheName')
    publicKey=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.publicKey')
    pushToken=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.pushToken')

    # Write nix substituter config
    ${pkgs.coreutils}/bin/cat > "${cacheConfFile}" <<EOF
extra-substituters = $respCacheUrl/$respCacheName
extra-trusted-public-keys = $publicKey
EOF
    ${pkgs.coreutils}/bin/chmod 644 "${cacheConfFile}"

    # Write push token
    echo "$pushToken" > "${pushTokenFile}"
    ${pkgs.coreutils}/bin/chmod 600 "${pushTokenFile}"
  '';

  # Post-deployment script to push built system to cache
  postDeployScript = pkgs.writeShellScript "comin-post-deploy-cache-push" ''
    set -euf
    export PATH="${lib.makeBinPath [ pkgs.attic-client pkgs.coreutils pkgs.util-linux ]}:$PATH"

    log() { logger -t comin-cache-push "$@"; }

    # Skip if push token doesn't exist yet (before attic-key-sync runs)
    if [ ! -s "${pushTokenFile}" ]; then
      log "Cache push token not available, skipping"
      exit 0
    fi

    # COMIN_STATUS is "done" on success (not "success")
    if [ "$COMIN_STATUS" != "done" ]; then
      log "Deployment status is $COMIN_STATUS, skipping cache push"
      exit 0
    fi

    # Get the current system profile (what comin just activated)
    SYSTEM_PATH=$(readlink -f /nix/var/nix/profiles/system)

    # Configure attic client
    export HOME=$(mktemp -d)
    trap 'rm -rf "$HOME"' EXIT
    mkdir -p "$HOME/.config/attic"
    cat > "$HOME/.config/attic/config.toml" <<EOF
default-server = "local"

[servers.local]
endpoint = "${cacheUrl}"
token = "$(cat ${pushTokenFile})"
EOF

    # Push the system closure to cache
    log "Pushing $SYSTEM_PATH to cache"
    if attic push ${cacheName} "$SYSTEM_PATH" 2>&1 | logger -t comin-cache-push; then
      log "Cache push complete"
    else
      log "Cache push failed (non-fatal)"
    fi
  '';
in
{
  # Ensure credential directories exist
  # Note: credDir is 0755 so dev-sandbox credential helper can read token files
  systemd.tmpfiles.rules = [
    "d ${credDir} 0755 root root -"
    "d ${cacheDir} 0755 root root -"
  ];

  # Request RO git token from forge for comin pulls
  fort.host.needs.git-token.default = {
    from = "drhorrible";
    request = { access = "ro"; };
    handler = gitTokenHandler;
  };

  # Request attic cache config and push token from forge
  fort.host.needs.attic-token.default = {
    from = "drhorrible";
    request = { };  # No parameters needed
    handler = atticTokenHandler;
  };

  services.comin = {
    enable = true;

    remotes = [{
      name = "origin";
      url = repoUrl;
      branches.main.name = "release";
      # Testing branch for safe experimentation (deployed with switch-to-configuration test)
      # Push to <hostname>-test on main, CI creates release-<hostname>-test
      branches.testing.name = "release-${hostManifest.hostName}-test";

      # Auth via deploy token distributed by forge
      auth.access_token_path = tokenFile;
    }];

    # Point to this host's flake within the repo
    # Each host has its own flake.nix at clusters/<cluster>/hosts/<hostname>/
    repositorySubdir = "clusters/${cluster.clusterName}/hosts/${hostManifest.hostName}";

    # Push built system to Attic cache after successful deployment
    postDeploymentCommand = postDeployScript;

    # Manual deploy mode: build automatically, but require explicit confirmation to switch
    # Triggered via fort <host> deploy '{"sha": "..."}'
    deployConfirmer.mode = if manualDeploy then "manual" else "without";
  };

  # Expose deploy capability for on-demand deployments
  fort.host.capabilities.deploy = {
    handler = "${deployProvider}/bin/deploy-provider";
    mode = "rpc";  # Synchronous deploy trigger
    description = "Trigger deployment after verifying expected SHA";
    allowed = [ "dev-sandbox" ];
  };

  # Comin needs git in PATH for fetching
  environment.systemPackages = [ pkgs.git ];
}
