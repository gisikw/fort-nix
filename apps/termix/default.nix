{ subdomain ? null, rootManifest, ... }:
{ pkgs, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;

  # Custom font bundled in apps/termix/
  proggyCleanFont = ./ProggyCleanNerdFontMono-Regular.ttf;

  # Font CSS to append to the stylesheet
  # Colors are handled by OSC escape sequences on SSH connection (see aspects/dev-sandbox)
  fontCss = ''
    @font-face{font-family:'ProggyClean Nerd Font';src:url('../fonts/ProggyCleanNerdFontMono-Regular.ttf') format('truetype');font-weight:normal;font-style:normal;font-display:swap}
    .xterm,.xterm-screen,.xterm-rows,[class*='xterm-dom-renderer-owner'] .xterm-rows{font-family:'ProggyClean Nerd Font',monospace !important}
  '';

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

      # Append font CSS to the stylesheet
      CSS_FILE=$(ls /app/html/assets/*.css 2>/dev/null | head -1)
      if [ -n "$CSS_FILE" ]; then
        echo '${fontCss}' >> "$CSS_FILE"
        echo "[fort] Appended font CSS to $CSS_FILE"
      else
        echo "[fort] Warning: Could not find CSS file to patch"
      fi

      echo "[fort] Starting Termix..."
      exec /entrypoint.sh
    '';
  };

  bootstrapScript = pkgs.writeShellScript "termix-oidc-bootstrap" ''
    set -euo pipefail

    TERMIX_URL="http://localhost:8080"
    ADMIN_CREDS="/var/lib/termix/admin-credentials.json"
    OIDC_CONFIGURED="/var/lib/termix/oidc-configured"
    CLIENT_ID_FILE="/var/lib/fort-auth/termix/client-id"
    CLIENT_SECRET_FILE="/var/lib/fort-auth/termix/client-secret"

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

    # Create admin user if credentials don't exist
    if [ ! -f "$ADMIN_CREDS" ]; then
      echo "Creating admin user..."
      ADMIN_USER="fort-admin"
      ADMIN_PASS=$(${pkgs.openssl}/bin/openssl rand -base64 32)

      response=$(${pkgs.curl}/bin/curl -sf "$TERMIX_URL/users/create" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")

      # Check if user was created and is admin
      is_admin=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.is_admin // false')
      if [ "$is_admin" = "true" ]; then
        echo "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" > "$ADMIN_CREDS"
        chmod 600 "$ADMIN_CREDS"
        echo "Admin user created successfully"
      else
        echo "User created but is_admin=$is_admin - database may already have users"
        echo "Response: $response"
        exit 1
      fi
    fi

    # Check if OIDC is already configured
    if [ -f "$OIDC_CONFIGURED" ]; then
      echo "OIDC already configured"
      exit 0
    fi

    # Wait for OIDC credentials from service-registry
    echo "Waiting for OIDC credentials..."
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

    # Read credentials
    ADMIN_USER=$(${pkgs.jq}/bin/jq -r '.username' "$ADMIN_CREDS")
    ADMIN_PASS=$(${pkgs.jq}/bin/jq -r '.password' "$ADMIN_CREDS")
    CLIENT_ID=$(cat "$CLIENT_ID_FILE")
    CLIENT_SECRET=$(cat "$CLIENT_SECRET_FILE")

    # Login to get JWT cookie
    echo "Logging in..."
    COOKIE_JAR=$(mktemp)
    login_response=$(${pkgs.curl}/bin/curl -sf -c "$COOKIE_JAR" "$TERMIX_URL/users/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")

    if ! echo "$login_response" | ${pkgs.jq}/bin/jq -e '.success == true' >/dev/null 2>&1; then
      echo "Failed to login: $login_response"
      rm -f "$COOKIE_JAR"
      exit 1
    fi
    echo "Login successful"

    # Configure OIDC
    echo "Configuring OIDC..."
    oidc_response=$(${pkgs.curl}/bin/curl -s -b "$COOKIE_JAR" "$TERMIX_URL/users/oidc-config" \
      -H "Content-Type: application/json" \
      -d "{
        \"client_id\": \"$CLIENT_ID\",
        \"client_secret\": \"$CLIENT_SECRET\",
        \"issuer_url\": \"https://id.${domain}\",
        \"authorization_url\": \"https://id.${domain}/authorize\",
        \"token_url\": \"https://id.${domain}/api/oidc/token\",
        \"userinfo_url\": \"https://id.${domain}/api/oidc/userinfo\",
        \"identifier_path\": \"sub\",
        \"name_path\": \"preferred_username\",
        \"scopes\": \"openid email profile\"
      }")
    echo "OIDC response: $oidc_response"

    # Disable password login (OIDC only)
    echo "Disabling password login..."
    ${pkgs.curl}/bin/curl -s -X PATCH -b "$COOKIE_JAR" "$TERMIX_URL/users/password-login-allowed" \
      -H "Content-Type: application/json" \
      -d '{"allowed":false}'

    rm -f "$COOKIE_JAR"
    touch "$OIDC_CONFIGURED"
    echo "OIDC configured successfully"
  '';
in
{
  virtualisation.oci-containers = {
    containers.termix = {
      image = "containers.${domain}/ghcr.io/lukegus/termix:release-1.10.0";
      ports = [ "8080:8080" ];
      volumes = [
        "/var/lib/termix:/app/data"
        "${proggyCleanFont}:/custom/ProggyCleanNerdFontMono-Regular.ttf:ro"
        "${patchEntrypoint}:/custom/entrypoint.sh:ro"
      ];
      entrypoint = "/custom/entrypoint.sh";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/termix 0777 root root -"
    "d /var/lib/fort-auth/termix 0755 root root -"
  ];

  systemd.services.termix-oidc-bootstrap = {
    after = [ "podman-termix.service" ];
    wants = [ "podman-termix.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = bootstrapScript;
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
        restart = "termix-oidc-bootstrap.service";
      };
    }
  ];
}
