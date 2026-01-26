# Runtime Packages Consumer Module
#
# Allows hosts to subscribe to CI-built packages from Forgejo.
# Packages are realized from attic and symlinked to /run/managed-bin.
#
# Usage in host manifest:
#   fort.host.runtimePackages = [
#     { repo = "infra/bz"; }
#     { repo = "infra/wicket"; constraint = "release"; }
#   ];
#
{ cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fort.host.runtimePackages;

  # Discover forge host (host with "forge" role)
  hostFiles = builtins.readDir cluster.hostsDir;
  allHostManifests = builtins.mapAttrs
    (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix"))
    hostFiles;
  forgeHosts = builtins.filter
    (h: builtins.elem "forge" h.roles)
    (builtins.attrValues allHostManifests);
  forgeHost = if forgeHosts != [] then (builtins.head forgeHosts).hostName else null;

  # Convert repo name to a safe identifier (replace / with -)
  repoToId = repo: builtins.replaceStrings [ "/" ] [ "-" ] repo;

  # Handler script for processing runtime package responses
  # Receives JSON on stdin: { repo, rev, storePath, updatedAt, error }
  runtimePackageHandler = pkgs.writeShellScript "handle-runtime-package" ''
    set -euo pipefail

    response=$(${pkgs.coreutils}/bin/cat)

    # Check for error in response
    error=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.error // empty')
    if [ -n "$error" ]; then
      echo "Error from provider: $error" >&2
      exit 1
    fi

    store_path=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.storePath // empty')
    repo=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.repo // empty')
    rev=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.rev // empty')

    if [ -z "$store_path" ]; then
      echo "No store path in response" >&2
      exit 1
    fi

    echo "Realizing $repo@$rev -> $store_path"

    # Realize the store path (pulls from attic if not local)
    if ! ${pkgs.nix}/bin/nix store realize "$store_path" 2>&1; then
      echo "Failed to realize store path: $store_path" >&2
      exit 1
    fi

    # Ensure managed-bin directory exists
    ${pkgs.coreutils}/bin/mkdir -p /run/managed-bin

    # Symlink all binaries from the store path
    if [ -d "$store_path/bin" ]; then
      for bin in "$store_path"/bin/*; do
        if [ -e "$bin" ]; then
          bin_name=$(${pkgs.coreutils}/bin/basename "$bin")
          ${pkgs.coreutils}/bin/ln -sf "$bin" "/run/managed-bin/$bin_name"
          echo "Linked $bin_name"
        fi
      done
    else
      echo "Warning: $store_path has no bin/ directory"
    fi

    echo "Deployed $repo@$rev"
  '';

  # Generate needs for each declared package
  packageNeeds = builtins.listToAttrs (map (pkg: {
    name = repoToId pkg.repo;
    value = {
      from = forgeHost;
      request = {
        repo = pkg.repo;
        constraint = pkg.constraint or "main";
      };
      handler = runtimePackageHandler;
      nag = "15m";
    };
  }) cfg);

in
{
  options.fort.host.runtimePackages = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        repo = lib.mkOption {
          type = lib.types.str;
          description = "Repository in owner/repo format (e.g., infra/bz)";
          example = "infra/bz";
        };
        constraint = lib.mkOption {
          type = lib.types.str;
          default = "main";
          description = "Branch or tag to track";
          example = "release";
        };
      };
    });
    default = [];
    description = ''
      List of runtime packages to subscribe to from the forge.
      Packages are CI-built, cached in attic, and delivered via the control plane.
      Binaries are symlinked to /run/managed-bin which is added to PATH.

      Example:
        fort.host.runtimePackages = [
          { repo = "infra/bz"; }
          { repo = "infra/wicket"; constraint = "release"; }
        ];
    '';
  };

  config = {
    # Register needs for runtime-package capability (only if packages declared)
    fort.host.needs.runtime-package = lib.mkIf (cfg != [] && forgeHost != null) packageNeeds;

    # Ensure /run/managed-bin directory exists (always, for handler)
    systemd.tmpfiles.rules = [
      "d /run/managed-bin 0755 root root -"
    ];

    # Add /run/managed-bin to PATH for all shells
    environment.extraInit = ''
      export PATH="/run/managed-bin:$PATH"
    '';
  };
}
