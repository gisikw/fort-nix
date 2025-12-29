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
    export PATH="${lib.makeBinPath [ pkgs.attic-client pkgs.coreutils pkgs.findutils ]}:$PATH"

    LOG="/var/lib/fort/nix/post-deploy.log"

    # Log all env vars for debugging
    echo "$(date): Post-deploy hook invoked" >> "$LOG"
    env | grep -i comin >> "$LOG" 2>&1 || true

    # Skip if push token doesn't exist yet (before attic-key-sync runs)
    if [ ! -s "${pushTokenFile}" ]; then
      echo "$(date): Cache push token not available, skipping" >> "$LOG"
      exit 0
    fi

    # COMIN_STATUS is "done" on success (not "success")
    if [ "$COMIN_STATUS" != "done" ]; then
      echo "$(date): Deployment status is $COMIN_STATUS, skipping cache push" >> "$LOG"
      exit 0
    fi

    # Get the current system profile (what comin just activated)
    SYSTEM_PATH=$(readlink -f /nix/var/nix/profiles/system)
    echo "$(date): System path: $SYSTEM_PATH" >> "$LOG"

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
    echo "$(date): Pushing to cache: $SYSTEM_PATH" >> "$LOG"
    if attic push ${cacheName} "$SYSTEM_PATH" 2>> "$LOG"; then
      echo "$(date): Cache push complete" >> "$LOG"
    else
      echo "$(date): Cache push failed (non-fatal)" >> "$LOG"
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
