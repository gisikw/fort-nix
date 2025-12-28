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

  # Declare the secret
  age.secrets.attic-server-token = {
    file = ./attic-server-token.age;
    owner = "atticd";
    group = "atticd";
  };

  # Bootstrap directory for tokens
  systemd.tmpfiles.rules = [
    "d ${bootstrapDir} 0700 atticd atticd -"
  ];

  # Bootstrap: create admin token and cache
  systemd.services.attic-bootstrap = {
    description = "Bootstrap Attic cache and tokens";
    after = [ "atticd.service" ];
    requires = [ "atticd.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.attic-client config.services.atticd.package ];

    serviceConfig = {
      Type = "oneshot";
      User = "atticd";
      Group = "atticd";
      WorkingDirectory = "/var/lib/atticd";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      ADMIN_TOKEN_FILE="${bootstrapDir}/admin-token"
      CI_TOKEN_FILE="${bootstrapDir}/ci-token"

      # Wait for atticd to be ready
      for i in $(seq 1 30); do
        if curl -sf "http://[::]:8080/" > /dev/null 2>&1; then
          break
        fi
        echo "Waiting for atticd..."
        sleep 2
      done

      # Create admin token if not exists
      if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        echo "Creating admin token"
        atticd-atticadm make-token \
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
        atticd-atticadm make-token \
          --sub "ci" \
          --validity "10y" \
          --push "${cacheName}" \
          --pull "*" \
          > "$CI_TOKEN_FILE"
        chmod 600 "$CI_TOKEN_FILE"
      fi

      ADMIN_TOKEN=$(cat "$ADMIN_TOKEN_FILE")

      # Configure attic CLI
      export XDG_CONFIG_HOME="${bootstrapDir}"
      mkdir -p "${bootstrapDir}/attic"

      cat > "${bootstrapDir}/attic/config.toml" <<EOF
      default-server = "local"

      [servers.local]
      endpoint = "${cacheUrl}"
      token = "$ADMIN_TOKEN"
      EOF

      # Create cache if not exists
      if ! attic cache info "${cacheName}" > /dev/null 2>&1; then
        echo "Creating cache: ${cacheName}"
        attic cache create "${cacheName}"
      else
        echo "Cache already exists: ${cacheName}"
      fi

      echo "Attic bootstrap complete"
    '';
  };

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
