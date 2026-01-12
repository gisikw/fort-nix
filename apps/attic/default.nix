{ subdomain ? "cache", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  bootstrapDir = "/var/lib/atticd/bootstrap";
  cacheUrl = "https://cache.${domain}";
  cacheName = "fort";

  # Handler for attic-token capability (async aggregate mode)
  # Input: {key -> {request: {}, response?}}
  # Output: {key -> {cacheUrl, cacheName, publicKey, pushToken}}
  # Returns cache configuration and push token for binary cache access
  atticTokenHandler = pkgs.writeShellScript "handler-attic-token" ''
    set -euo pipefail

    # Read aggregate input
    input=$(${pkgs.coreutils}/bin/cat)

    CI_TOKEN_FILE="${bootstrapDir}/ci-token"
    PUBLIC_KEY_FILE="${bootstrapDir}/public-key"

    # Ensure we have the CI token
    if [ ! -s "$CI_TOKEN_FILE" ]; then
      # Return error for all keys
      echo "$input" | ${pkgs.jq}/bin/jq 'to_entries | map({key: .key, value: {error: "CI token not yet created"}}) | from_entries'
      exit 0
    fi

    # Cache the public key if not already cached
    if [ ! -s "$PUBLIC_KEY_FILE" ]; then
      # Configure attic client to get cache info
      export HOME=$(${pkgs.coreutils}/bin/mktemp -d)
      trap '${pkgs.coreutils}/bin/rm -rf "$HOME"' EXIT
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/attic"

      ADMIN_TOKEN_FILE="${bootstrapDir}/admin-token"
      if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        echo "$input" | ${pkgs.jq}/bin/jq 'to_entries | map({key: .key, value: {error: "Admin token not yet created"}}) | from_entries'
        exit 0
      fi

      ${pkgs.coreutils}/bin/cat > "$HOME/.config/attic/config.toml" <<EOF
default-server = "local"

[servers.local]
endpoint = "${cacheUrl}"
token = "$(${pkgs.coreutils}/bin/cat $ADMIN_TOKEN_FILE)"
EOF

      # Get the cache public key
      PUBLIC_KEY=$(${pkgs.attic-client}/bin/attic cache info ${cacheName} 2>&1 | ${pkgs.gawk}/bin/awk '/Public Key:/ {print $NF}')
      if [ -z "$PUBLIC_KEY" ]; then
        echo "$input" | ${pkgs.jq}/bin/jq 'to_entries | map({key: .key, value: {error: "Could not get cache public key"}}) | from_entries'
        exit 0
      fi

      echo "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
    fi

    CI_TOKEN=$(${pkgs.coreutils}/bin/cat "$CI_TOKEN_FILE")
    PUBLIC_KEY=$(${pkgs.coreutils}/bin/cat "$PUBLIC_KEY_FILE")

    # Build response for all requesters (same config for everyone)
    output='{}'
    for key in $(echo "$input" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
      output=$(echo "$output" | ${pkgs.jq}/bin/jq \
        --arg k "$key" \
        --arg url "${cacheUrl}" \
        --arg name "${cacheName}" \
        --arg pk "$PUBLIC_KEY" \
        --arg token "$CI_TOKEN" \
        '.[$k] = {cacheUrl: $url, cacheName: $name, publicKey: $pk, pushToken: $token}')
    done

    echo "$output"
  '';
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
    handler = atticTokenHandler;
    mode = "async";  # Returns handles, needs GC
    cacheResponse = true;  # Reuse same token for all consumers
    description = "Distribute binary cache config and push token";
  };
}
