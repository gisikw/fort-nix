{
  rootManifest,
  hostManifest,
  cluster,
  ...
}:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;
  credDir = "/var/lib/fort-git";
  tokenFile = "${credDir}/deploy-token";

  repoUrl = "https://git.${domain}/${forgeConfig.org}/${forgeConfig.repo}.git";

  # Cache configuration
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";
  pushTokenFile = "/var/lib/fort/nix/attic-push-token";

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
  # Ensure credential directory exists
  systemd.tmpfiles.rules = [
    "d ${credDir} 0700 root root -"
  ];

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
  };

  # Comin needs git in PATH for fetching
  environment.systemPackages = [ pkgs.git ];
}
