{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  bootstrapDir = "/var/lib/atticd/bootstrap";
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";
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

  # Bootstrap script that runs after atticd starts (as same dynamic user)
  systemd.services.atticd.serviceConfig.ExecStartPost = let
    bootstrapScript = pkgs.writeShellScript "attic-bootstrap" ''
      set -euo pipefail
      export PATH="${pkgs.coreutils}/bin:${config.services.atticd.package}/bin:$PATH"
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
        echo "Creating admin token"
        atticadm make-token \
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
      fi

      # Create CI token (push/pull only) if not exists
      if [ ! -s "$CI_TOKEN_FILE" ]; then
        echo "Creating CI token"
        atticadm make-token \
          --sub "ci" \
          --validity "10y" \
          --push "${cacheName}" \
          --pull "*" \
          > "$CI_TOKEN_FILE"
        chmod 600 "$CI_TOKEN_FILE"
      fi

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
        ${pkgs.attic-client}/bin/attic cache create "${cacheName}"
      else
        echo "Cache already exists: ${cacheName}"
      fi

      echo "Attic bootstrap complete"
    '';
  in "+${bootstrapScript}"; # + runs as root to read credentials file

  # Expose via reverse proxy
  fortCluster.exposedServices = [
    {
      name = "attic";
      subdomain = "cache";
      port = 8080;
      visibility = "vpn"; # Cache access is token-based, VPN-only for now
    }
  ];
}
