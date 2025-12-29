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
    export PATH="${lib.makeBinPath [ pkgs.attic-client pkgs.coreutils ]}:$PATH"

    # Skip if push token doesn't exist yet (before attic-key-sync runs)
    if [ ! -s "${pushTokenFile}" ]; then
      echo "Cache push token not available, skipping cache push"
      exit 0
    fi

    # Only push on successful deployments
    if [ "$COMIN_STATUS" != "success" ]; then
      echo "Deployment status is $COMIN_STATUS, skipping cache push"
      exit 0
    fi

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

    # Push the deployed generation to cache
    # COMIN_GENERATION contains the store path of the activated system
    if [ -n "''${COMIN_GENERATION:-}" ]; then
      echo "Pushing to cache: $COMIN_GENERATION"
      attic push ${cacheName} "$COMIN_GENERATION" || echo "Cache push failed (non-fatal)"
    else
      echo "COMIN_GENERATION not set, skipping cache push"
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
