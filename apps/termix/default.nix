{ subdomain ? null, rootManifest, ... }:
{ pkgs, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;

  # Import db tools
  termixDbTools = import ../../pkgs/termix-db-tools { inherit pkgs; };

  # Custom font bundled in apps/termix/
  proggyCleanFont = ./ProggyCleanNerdFontMono-Regular.ttf;

  # Font CSS to load the custom font (no override - JS sets fontFamily on xterm instance)
  # Colors are handled by OSC escape sequences on SSH connection (see aspects/dev-sandbox)
  fontCss = ''
    @font-face{font-family:'ProggyClean Nerd Font';src:url('../fonts/ProggyCleanNerdFontMono-Regular.ttf') format('truetype');font-weight:normal;font-style:normal;font-display:block}
  '';

  # Font JS file - patches xterm terminal instances to use custom font
  # Debug handles exposed at window.__fort
  fontJsFile = ./termix-font.js;

  # Patch script that injects custom font before starting Termix
  patchEntrypoint = pkgs.writeTextFile {
    name = "termix-patch-entrypoint";
    executable = true;
    text = ''
      #!/bin/sh
      set -e

      echo "[fort] Patching Termix with custom font..."

      # Copy custom font to static assets
      cp /custom/ProggyCleanNerdFontMono-Regular.ttf /app/html/fonts/
      echo "[fort] Copied ProggyClean font"

      # Copy font JS to static assets
      cp /custom/termix-font.js /app/html/assets/
      echo "[fort] Copied font JS"

      # Append font CSS to the stylesheet
      CSS_FILE=$(ls /app/html/assets/*.css 2>/dev/null | head -1)
      if [ -n "$CSS_FILE" ]; then
        echo '${fontCss}' >> "$CSS_FILE"
        echo "[fort] Appended font CSS to $CSS_FILE"
      else
        echo "[fort] Warning: Could not find CSS file to patch"
      fi

      # Inject font JS reference into HTML (before closing </head>)
      HTML_FILE="/app/html/index.html"
      if [ -f "$HTML_FILE" ]; then
        sed -i 's|</head>|<script src="/assets/termix-font.js"></script></head>|' "$HTML_FILE"
        echo "[fort] Injected font JS reference into $HTML_FILE"
      else
        echo "[fort] Warning: Could not find index.html to patch"
      fi

      echo "[fort] Starting Termix..."
      exec /entrypoint.sh
    '';
  };

  # Script to create throwaway admin user (burns first-user-is-admin)
  createAdminScript = pkgs.writeShellScript "termix-create-admin" ''
    set -euo pipefail

    TERMIX_URL="http://localhost:8080"
    ADMIN_CREATED="/var/lib/termix/admin-created"

    # Skip if already done
    if [ -f "$ADMIN_CREATED" ]; then
      echo "Admin already created, skipping"
      exit 0
    fi

    # Wait for termix to be healthy
    echo "Waiting for Termix to be ready..."
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf "$TERMIX_URL" >/dev/null 2>&1; then
        echo "Termix is ready"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "Timeout waiting for Termix"
        exit 1
      fi
      sleep 2
    done

    # Create throwaway admin user (we don't store these - just burning the first-user-is-admin)
    echo "Creating throwaway admin user..."
    ADMIN_USER="fort-admin-$(${pkgs.openssl}/bin/openssl rand -hex 4)"
    ADMIN_PASS=$(${pkgs.openssl}/bin/openssl rand -base64 32)

    response=$(${pkgs.curl}/bin/curl -sf "$TERMIX_URL/users/create" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" || echo '{}')

    is_admin=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.is_admin // false')
    if [ "$is_admin" = "true" ]; then
      echo "Admin user created successfully (credentials discarded)"
      touch "$ADMIN_CREATED"
    else
      echo "Warning: User created but is_admin=$is_admin - database may already have users"
      echo "Response: $response"
      # Still mark as done - we tried
      touch "$ADMIN_CREATED"
    fi
  '';

  # Script to patch OIDC config directly in the database
  # Takes client_id, client_secret as arguments
  patchDbScript = pkgs.writeShellScript "termix-patch-db" ''
    set -euo pipefail

    CLIENT_ID="$1"
    CLIENT_SECRET="$2"
    ISSUER_URL="https://id.${domain}"

    TERMIX_DATA="/var/lib/termix"
    ENCRYPTED_DB="$TERMIX_DATA/db.sqlite.encrypted"
    TMP_DB=$(${pkgs.coreutils}/bin/mktemp)

    # Check encrypted DB exists
    if [ ! -f "$ENCRYPTED_DB" ]; then
      echo "Error: Encrypted database not found at $ENCRYPTED_DB"
      exit 1
    fi

    # Read encryption key
    KEY=$(${pkgs.gnugrep}/bin/grep DATABASE_KEY "$TERMIX_DATA/.env" | ${pkgs.coreutils}/bin/cut -d'=' -f2)
    if [ -z "$KEY" ]; then
      echo "Error: DATABASE_KEY not found in $TERMIX_DATA/.env"
      exit 1
    fi

    # Decrypt
    echo "Decrypting database..."
    ${termixDbTools}/bin/termix-db-decrypt "$ENCRYPTED_DB" "$KEY" "$TMP_DB"

    # Build OIDC config JSON
    OIDC_CONFIG=$(${pkgs.jq}/bin/jq -n \
      --arg cid "$CLIENT_ID" \
      --arg cs "$CLIENT_SECRET" \
      --arg iss "$ISSUER_URL" \
      '{
        client_id: $cid,
        client_secret: $cs,
        issuer_url: $iss,
        authorization_url: ($iss + "/authorize"),
        token_url: ($iss + "/api/oidc/token"),
        userinfo_url: ($iss + "/api/oidc/userinfo"),
        identifier_path: "sub",
        name_path: "preferred_username",
        scopes: "openid email profile"
      }')

    # Patch the database
    echo "Patching OIDC config..."
    ${pkgs.sqlite}/bin/sqlite3 "$TMP_DB" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('oidc_config', '$OIDC_CONFIG');
INSERT OR REPLACE INTO settings (key, value) VALUES ('allow_password_login', 'false');
EOF

    # Re-encrypt
    echo "Re-encrypting database..."
    ${termixDbTools}/bin/termix-db-encrypt "$TMP_DB" "$KEY" "$ENCRYPTED_DB"

    # Cleanup
    ${pkgs.coreutils}/bin/rm -f "$TMP_DB"
    echo "Database patched successfully"
  '';

  # Unified OIDC config service - handles both initial setup and rotation
  # Reads from /var/lib/fort-auth/termix/ (where control plane writes)
  # Compares against /var/lib/termix/oidc-cache/ to avoid noop restarts
  oidcConfigScript = pkgs.writeShellScript "termix-oidc-config" ''
    set -euo pipefail

    AUTH_DIR="/var/lib/fort-auth/termix"
    CACHE_DIR="/var/lib/termix/oidc-cache"
    CLIENT_ID_FILE="$AUTH_DIR/client-id"
    CLIENT_SECRET_FILE="$AUTH_DIR/client-secret"

    # Wait for OIDC credentials (control plane delivers them)
    echo "Checking for OIDC credentials..."
    if [ ! -f "$CLIENT_ID_FILE" ] || [ ! -f "$CLIENT_SECRET_FILE" ]; then
      echo "OIDC credentials not yet available, waiting..."
      for i in $(seq 1 120); do
        if [ -f "$CLIENT_ID_FILE" ] && [ -f "$CLIENT_SECRET_FILE" ]; then
          echo "OIDC credentials found"
          break
        fi
        if [ "$i" -eq 120 ]; then
          echo "Timeout waiting for OIDC credentials"
          exit 1
        fi
        sleep 5
      done
    fi

    # Read incoming credentials
    CLIENT_ID=$(${pkgs.coreutils}/bin/cat "$CLIENT_ID_FILE")
    CLIENT_SECRET=$(${pkgs.coreutils}/bin/cat "$CLIENT_SECRET_FILE")

    # Compare against cache
    ${pkgs.coreutils}/bin/mkdir -p "$CACHE_DIR"
    CACHED_ID=""
    CACHED_SECRET=""
    if [ -f "$CACHE_DIR/client-id" ]; then
      CACHED_ID=$(${pkgs.coreutils}/bin/cat "$CACHE_DIR/client-id")
    fi
    if [ -f "$CACHE_DIR/client-secret" ]; then
      CACHED_SECRET=$(${pkgs.coreutils}/bin/cat "$CACHE_DIR/client-secret")
    fi

    if [ "$CLIENT_ID" = "$CACHED_ID" ] && [ "$CLIENT_SECRET" = "$CACHED_SECRET" ]; then
      echo "OIDC credentials unchanged, skipping"
      exit 0
    fi

    echo "OIDC credentials changed, updating database..."

    # Stop the container (triggers clean shutdown and DB flush)
    echo "Stopping termix container..."
    ${pkgs.systemd}/bin/systemctl stop podman-termix.service || true
    sleep 2  # Give it time to flush

    # Patch the database
    ${patchDbScript} "$CLIENT_ID" "$CLIENT_SECRET"

    # Update cache
    ${pkgs.coreutils}/bin/printf '%s' "$CLIENT_ID" > "$CACHE_DIR/client-id"
    ${pkgs.coreutils}/bin/printf '%s' "$CLIENT_SECRET" > "$CACHE_DIR/client-secret"

    # Start the container
    echo "Starting termix container..."
    ${pkgs.systemd}/bin/systemctl start podman-termix.service

    echo "OIDC configuration complete"
  '';
in
{
  virtualisation.oci-containers = {
    containers.termix = {
      image = "containers.${domain}/ghcr.io/lukegus/termix:release-1.10.0";
      ports = [ "127.0.0.1:8080:8080" ];
      volumes = [
        "/var/lib/termix:/app/data"
        "${proggyCleanFont}:/custom/ProggyCleanNerdFontMono-Regular.ttf:ro"
        "${fontJsFile}:/custom/termix-font.js:ro"
        "${patchEntrypoint}:/custom/entrypoint.sh:ro"
      ];
      entrypoint = "/custom/entrypoint.sh";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/termix 0777 root root -"
    "d /var/lib/termix/oidc-cache 0700 root root -"
    "d /var/lib/fort-auth/termix 0755 root root -"
  ];

  # Initial setup: create throwaway admin to burn first-user-is-admin
  systemd.services.termix-admin-setup = {
    after = [ "podman-termix.service" ];
    wants = [ "podman-termix.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = createAdminScript;
    };
  };

  # OIDC configuration: runs after admin setup, handles both initial and rotation
  # Triggered by control plane via sso.restart when credentials change
  systemd.services.termix-oidc-config = {
    after = [ "termix-admin-setup.service" ];
    wants = [ "termix-admin-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = oidcConfigScript;
    };
  };

  fort.cluster.services = [
    {
      name = "termix";
      subdomain = subdomain;
      port = 8080;
      visibility = "public";
      sso = {
        mode = "oidc";
        # When control plane delivers new creds, re-run the config service
        restart = "termix-oidc-config.service";
      };
    }
  ];
}
