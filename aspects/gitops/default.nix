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

  # Cache configuration
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";
  pushTokenFile = "/var/lib/fort/nix/attic-push-token";

  # Comin binary for CLI commands
  cominBin = config.services.comin.package;

  # Handler for git-token: extracts token from JSON response and stores it
  gitTokenHandler = pkgs.writeShellScript "git-token-handler" ''
    ${pkgs.coreutils}/bin/mkdir -p "${credDir}"
    ${pkgs.jq}/bin/jq -r '.token' > "${tokenFile}"
    ${pkgs.coreutils}/bin/chmod 600 "${tokenFile}"
  '';

  # Deploy handler - verifies SHA then confirms deployment
  deployHandler = pkgs.writeShellScript "handler-deploy" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.jq pkgs.coreutils cominBin ]}:$PATH"

    # Read expected SHA from request
    input=$(cat)
    expected_sha=$(echo "$input" | jq -r '.sha // empty')

    if [ -z "$expected_sha" ]; then
      echo '{"error": "sha parameter required"}'
      exit 1
    fi

    COMIN_REPO="/var/lib/comin/repository"

    # Get release branch HEAD commit message
    # Format: "release: 5563ac2 - 2025-12-31T19:44:27+00:00"
    if ! release_msg=$(git -C "$COMIN_REPO" log -1 --format=%s HEAD 2>&1); then
      jq -n --arg err "$release_msg" '{"error": "failed to read release HEAD", "details": $err}'
      exit 1
    fi

    # Parse the main SHA from the commit message
    pending_sha=$(echo "$release_msg" | sed -n 's/^release: \([a-f0-9]*\) -.*/\1/p')

    if [ -z "$pending_sha" ]; then
      jq -n --arg msg "$release_msg" '{"error": "could not parse SHA from release commit", "commit_message": $msg}'
      exit 1
    fi

    # Verify SHA matches (allow prefix match for short SHAs)
    if [[ ! "$pending_sha" == "$expected_sha"* ]] && [[ ! "$expected_sha" == "$pending_sha"* ]]; then
      jq -n --arg expected "$expected_sha" --arg pending "$pending_sha" \
        '{"error": "sha_mismatch", "expected": $expected, "pending": $pending}'
      exit 0  # Exit 0 so wrapper returns our JSON, not a 500
    fi

    # SHA matches - trigger confirmation
    if output=$(comin confirmation accept 2>&1); then
      # Check if confirmation was actually accepted (not just command success)
      if echo "$output" | grep -q "accepted for deploying"; then
        jq -n --arg sha "$pending_sha" --arg output "$output" \
          '{"status": "deployed", "sha": $sha, "output": $output}'
      else
        # Command succeeded but nothing was accepted (generation still building?)
        jq -n --arg sha "$pending_sha" --arg output "$output" \
          '{"error": "building", "sha": $sha, "note": "generation not ready for confirmation yet", "output": $output}'
      fi
    else
      jq -n --arg sha "$pending_sha" --arg output "$output" \
        '{"status": "confirmed", "sha": $sha, "note": "no confirmation was pending (may have auto-deployed)", "output": $output}'
    fi
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
  # Ensure credential directory exists
  systemd.tmpfiles.rules = [
    "d ${credDir} 0700 root root -"
  ];

  # Request RO git token from forge for comin pulls
  fort.host.needs.git-token.default = {
    from = "drhorrible";
    request = { access = "ro"; };
    handler = gitTokenHandler;
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
    handler = deployHandler;
    description = "Trigger deployment after verifying expected SHA";
    allowed = [ "dev-sandbox" ];
  };

  # Comin needs git in PATH for fetching
  environment.systemPackages = [ pkgs.git ];
}
