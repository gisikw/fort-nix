{ subdomain ? "cache", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  bootstrapDir = "/var/lib/atticd/bootstrap";
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";

  # Go handler for attic-token capability
  atticTokenProvider = import ./provider {
    inherit pkgs;
    cacheURL = cacheUrl;
    inherit cacheName;
  };
in
{
  services.atticd = {
    enable = true;

    # Environment file containing ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64
    environmentFile = config.age.secrets.attic-server-token.path;

    settings = {
      listen = "[::]:8080";

      # API endpoint for token generation
      api-endpoint = cacheUrl;

      # Use local SQLite database (persisted via /var/lib)
      database.url = "sqlite:///var/lib/atticd/server.db?mode=rwc";

      # Local storage backend
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      # Chunking settings for deduplication
      chunking = {
        nar-size-threshold = 65536; # 64 KiB
        min-size = 16384; # 16 KiB
        avg-size = 65536; # 64 KiB
        max-size = 262144; # 256 KiB
      };

      # Garbage collection
      garbage-collection = {
        interval = "24h";
        default-retention-period = "30d";
      };

      # Use zstd compression
      compression = {
        type = "zstd";
      };
    };
  };

  # Declare the secret (root-owned, atticd reads via EnvironmentFile)
  age.secrets.attic-server-token.file = ./attic-server-token.age;

  # Bootstrap script that runs after atticd starts
  systemd.services.atticd.serviceConfig.ExecStartPost = let
    atticadm = "${config.services.atticd.package}/bin/atticadm";
    # Generate config file using the same format as nixpkgs module
    # This ensures atticadm gets all required fields (chunking, storage, etc.)
    format = pkgs.formats.toml { };
    atticadmConfig = format.generate "atticadm-config.toml" config.services.atticd.settings;
    bootstrapScript = pkgs.writeShellScript "attic-bootstrap" ''
      set -euo pipefail
      export PATH="${pkgs.coreutils}/bin:$PATH"
      export HOME="/var/lib/atticd"

      # Source credentials (ExecStartPost may not inherit EnvironmentFile)
      set -a
      source ${config.age.secrets.attic-server-token.path}
      set +a

      BOOTSTRAP_DIR="/var/lib/atticd/bootstrap"
      ADMIN_TOKEN_FILE="$BOOTSTRAP_DIR/admin-token"
      CI_TOKEN_FILE="$BOOTSTRAP_DIR/ci-token"

      mkdir -p "$BOOTSTRAP_DIR"

      # Wait for atticd to be ready (it might still be initializing)
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -sf "http://[::]:8080/" > /dev/null 2>&1; then
          break
        fi
        echo "Waiting for atticd..."
        sleep 2
      done

      # Create admin token if not exists
      if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        echo "Creating admin token..."
        ${atticadm} -f ${atticadmConfig} make-token \
          --sub "admin" \
          --validity "10y" \
          --push "*" \
          --pull "*" \
          --create-cache "*" \
          --configure-cache "*" \
          --configure-cache-retention "*" \
          --destroy-cache "*" \
          --delete "*" \
          > "$ADMIN_TOKEN_FILE"
        chmod 600 "$ADMIN_TOKEN_FILE"
        echo "Admin token created"
      fi

      # Create CI token (push/pull only) if not exists
      # Readable by forgejo for CI runner access
      if [ ! -s "$CI_TOKEN_FILE" ]; then
        echo "Creating CI token..."
        ${atticadm} -f ${atticadmConfig} make-token \
          --sub "ci" \
          --validity "10y" \
          --push "${cacheName}" \
          --pull "*" \
          > "$CI_TOKEN_FILE"
        echo "CI token created"
      fi
      # Ensure CI token is readable by forgejo (fix existing permissions)
      chown forgejo:forgejo "$CI_TOKEN_FILE"
      chmod 640 "$CI_TOKEN_FILE"

      # Configure attic CLI for cache creation
      ADMIN_TOKEN=$(cat "$ADMIN_TOKEN_FILE")
      export XDG_CONFIG_HOME="$BOOTSTRAP_DIR"
      mkdir -p "$BOOTSTRAP_DIR/attic"

      cat > "$BOOTSTRAP_DIR/attic/config.toml" <<EOF
default-server = "local"

[servers.local]
endpoint = "${cacheUrl}"
token = "$ADMIN_TOKEN"
EOF

      # Create cache if not exists
      if ! ${pkgs.attic-client}/bin/attic cache info "${cacheName}" > /dev/null 2>&1; then
        echo "Creating cache: ${cacheName}"
        ${pkgs.attic-client}/bin/attic cache create --public "${cacheName}"
      else
        echo "Cache already exists: ${cacheName}"
      fi

      # Ensure cache is public (for nix to pull without auth - network is VPN-only)
      ${pkgs.attic-client}/bin/attic cache configure --public "${cacheName}" || true

      echo "Attic bootstrap complete"
    '';
  in "+${bootstrapScript}"; # + runs as root to read credentials file

  # Post-build hook to push all builds to the cache
  # Runs after every nix build on this host, warming the cache automatically
  nix.settings.post-build-hook = let
    ciTokenFile = "${bootstrapDir}/ci-token";
    uploadScript = pkgs.writeShellScript "upload-to-cache" ''
      set -euf
      export PATH="${lib.makeBinPath [ pkgs.attic-client pkgs.coreutils ]}:$PATH"

      # Skip if token doesn't exist yet (before bootstrap)
      if [ ! -s "${ciTokenFile}" ]; then
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
      token = "$(cat ${ciTokenFile})"
      EOF

      # Push paths to cache (ignore failures - cache may be temporarily unavailable)
      if [ -n "''${OUT_PATHS:-}" ]; then
        echo "Uploading to cache: $OUT_PATHS"
        attic push ${cacheName} $OUT_PATHS || true
      fi
    '';
  in "${uploadScript}";

  # Expose via reverse proxy
  fort.cluster.services = [
    {
      name = "attic";
      subdomain = subdomain;
      port = 8080;
      visibility = "vpn"; # Cache access is token-based, VPN-only for now
      maxBodySize = "2G"; # Large uploads for binary cache (kernel, initrd, etc.)
    }
  ];

  # Expose attic-token capability for cache config distribution
  fort.host.capabilities.attic-token = {
    handler = "${atticTokenProvider}/bin/attic-token-provider";
    mode = "async";
    format = "symmetric";  # Go handler uses symmetric input/output format
    cacheResponse = true;  # Reuse same config for all consumers
    description = "Distribute binary cache config and push token";
  };
}
