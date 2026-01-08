{ subdomain ? null, rootManifest, ... }:
{ pkgs, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;

  # Monokai Pro Spectrum theme (from iTerm2-Color-Schemes/ghostty)
  monokaiProSpectrum = {
    background = "#222222";
    foreground = "#f7f1ff";
    cursor = "#bab6c0";
    cursorAccent = "#222222";
    selectionBackground = "#525053";
    selectionForeground = "#f7f1ff";
    black = "#222222";
    red = "#fc618d";
    green = "#7bd88f";
    yellow = "#fce566";
    blue = "#fd9353";
    magenta = "#948ae3";
    cyan = "#5ad4e6";
    white = "#f7f1ff";
    brightBlack = "#69676c";
    brightRed = "#fc618d";
    brightGreen = "#7bd88f";
    brightYellow = "#fce566";
    brightBlue = "#fd9353";
    brightMagenta = "#948ae3";
    brightCyan = "#5ad4e6";
    brightWhite = "#f7f1ff";
  };

  # Custom font bundled in apps/termix/
  proggyCleanFont = ./ProggyCleanNerdFontMono-Regular.ttf;

  # Patch script that injects theme and font before starting Termix
  # Uses writeTextFile to get a plain #!/bin/sh shebang that works inside the container
  patchEntrypoint = pkgs.writeTextFile {
    name = "termix-patch-entrypoint";
    executable = true;
    text = ''
      #!/bin/sh
      set -e

      echo "[fort] Patching Termix with custom theme and font..."

      # Copy custom font to static assets
      cp /custom/ProggyCleanNerdFontMono-Regular.ttf /app/html/fonts/
      echo "[fort] Copied ProggyClean font"

      # Find ALL JS chunks containing terminal themes/fonts (desktop + mobile)
      CHUNKS=$(grep -l 'Caskaydia\|Dracula' /app/html/assets/*.js 2>/dev/null)

      if [ -n "$CHUNKS" ]; then
        echo "[fort] Found chunks to patch: $(echo $CHUNKS | wc -w)"

        # Create patch script
        cat > /tmp/patch.js << 'PATCHJS'
      const fs = require('fs');
      const chunk = process.argv[2];
      let content = fs.readFileSync(chunk, 'utf8');
      let modified = false;

      // Add ProggyClean font to TERMINAL_FONTS array
      // First font is Caskaydia - look for [{value:"Caskaydia and prepend our font
      const fontPattern = /(\[\s*)(\{value:"Caskaydia)/g;
      if (fontPattern.test(content)) {
        fontPattern.lastIndex = 0; // Reset for replace
        const proggyEntry = '{value:"ProggyClean Nerd Font",label:"ProggyClean Nerd Font",fallback:"\\"ProggyClean Nerd Font\\", monospace"},';
        content = content.replace(fontPattern, '$1' + proggyEntry + '$2');
        console.log('[fort] Added ProggyClean to font list');
        modified = true;
      }

      // Add @font-face for ProggyClean alongside existing Caskaydia fonts
      // Match existing @font-face and append ours
      const fontFacePattern = /(@font-face\s*\{[^}]*Caskaydia[^}]*\})/;
      if (fontFacePattern.test(content)) {
        const proggyFontFace = " @font-face{font-family:'ProggyClean Nerd Font';src:url('./fonts/ProggyCleanNerdFontMono-Regular.ttf') format('truetype');font-weight:normal;font-style:normal;font-display:swap}";
        content = content.replace(fontFacePattern, '$1' + proggyFontFace);
        console.log('[fort] Added ProggyClean @font-face');
        modified = true;
      }

      // Add Monokai Pro Spectrum theme after dracula
      // Use global flag to catch all instances (desktop + mobile may have separate copies)
      const draculaPattern = /(dracula:\s*\{[^}]*name:\s*"Dracula"[^}]*colors:\s*\{[^}]+\}\s*\})/g;
      const monokaiTheme = ',monokaiProSpectrum:{name:"Monokai Pro Spectrum",category:"dark",colors:{background:"#222222",foreground:"#f7f1ff",cursor:"#bab6c0",cursorAccent:"#222222",selectionBackground:"#525053",selectionForeground:"#f7f1ff",black:"#222222",red:"#fc618d",green:"#7bd88f",yellow:"#fce566",blue:"#fd9353",magenta:"#948ae3",cyan:"#5ad4e6",white:"#f7f1ff",brightBlack:"#69676c",brightRed:"#fc618d",brightGreen:"#7bd88f",brightYellow:"#fce566",brightBlue:"#fd9353",brightMagenta:"#948ae3",brightCyan:"#5ad4e6",brightWhite:"#f7f1ff"}}';
      const matches = content.match(draculaPattern);
      if (matches) {
        console.log('[fort] Found ' + matches.length + ' dracula theme instance(s)');
        content = content.replace(draculaPattern, '$1' + monokaiTheme);
        console.log('[fort] Added Monokai Pro Spectrum theme');
        modified = true;
      }

      if (modified) {
        fs.writeFileSync(chunk, content);
        console.log('[fort] Saved patched chunk: ' + chunk);
      }
      PATCHJS

        for CHUNK in $CHUNKS; do
          echo "[fort] Patching chunk: $CHUNK"
          node /tmp/patch.js "$CHUNK"
        done
        rm /tmp/patch.js
      else
        echo "[fort] Warning: Could not find JS chunks to patch"
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
