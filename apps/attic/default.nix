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
      if [ ! -s "$CI_TOKEN_FILE" ]; then
        echo "Creating CI token..."
        ${atticadm} -f ${atticadmConfig} make-token \
          --sub "ci" \
          --validity "10y" \
          --push "${cacheName}" \
          --pull "*" \
          > "$CI_TOKEN_FILE"
        chmod 600 "$CI_TOKEN_FILE"
        echo "CI token created"
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

  # Sync cache public key to all hosts in the mesh
  # This allows hosts to trust and pull from the cache
  systemd.timers."attic-key-sync" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";      # First run 2min after boot (after bootstrap completes)
      OnUnitActiveSec = "10m";
    };
  };

  systemd.services."attic-key-sync" = {
    path = with pkgs; [
      attic-client
      tailscale
      jq
      openssh
      coreutils
      gnugrep
    ];
    script = ''
      set -euo pipefail
      SSH_OPTS="-i /root/.ssh/deployer_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10"

      # Configure attic client to talk to local server
      export HOME=$(mktemp -d)
      trap 'rm -rf "$HOME"' EXIT
      mkdir -p "$HOME/.config/attic"

      ADMIN_TOKEN_FILE="${bootstrapDir}/admin-token"
      if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        echo "Admin token not yet created, skipping key sync"
        exit 0
      fi

      cat > "$HOME/.config/attic/config.toml" <<EOF
      default-server = "local"

      [servers.local]
      endpoint = "${cacheUrl}"
      token = "$(cat $ADMIN_TOKEN_FILE)"
      EOF

      # Get the cache public key
      PUBLIC_KEY=$(attic cache info ${cacheName} 2>/dev/null | grep "Public Key:" | cut -d' ' -f3-)
      if [ -z "$PUBLIC_KEY" ]; then
        echo "Could not get public key for cache ${cacheName}"
        exit 1
      fi
      echo "Cache public key: $PUBLIC_KEY"

      # Build the nix config snippet
      NIX_CONF="extra-substituters = ${cacheUrl}
      extra-trusted-public-keys = $PUBLIC_KEY"

      # Enumerate all hosts in the mesh
      mesh=$(tailscale status --json)
      user=$(echo $mesh | jq -r '.User | to_entries[] | select(.value.LoginName == "fort") | .key')
      peers=$(echo $mesh | jq -r --arg user "$user" '.Peer | to_entries[] | select(.value.UserID == ($user | tonumber)) | .value.DNSName')

      for peer in localhost $peers; do
        echo "Syncing cache key to $peer..."
        if ssh $SSH_OPTS "$peer" "
          mkdir -p /var/lib/fort/nix
          cat > /var/lib/fort/nix/attic-cache.conf << 'NIXCONF'
      $NIX_CONF
      NIXCONF
          chmod 644 /var/lib/fort/nix/attic-cache.conf
        "; then
          echo "Key synced to $peer"
        else
          echo "Failed to sync to $peer, continuing..."
        fi
      done

      echo "Cache key sync complete"
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
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
