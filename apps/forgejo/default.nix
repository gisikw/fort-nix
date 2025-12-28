{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;
  authDir = "/var/lib/fort-auth/git";
  oidcPath = "/user/oauth2/Pocket%20ID";
  bootstrapDir = "/var/lib/forgejo/bootstrap";
  runnerDir = "/var/lib/forgejo-runner";
  mirrorNames = builtins.attrNames forgeConfig.mirrors;
in
{
  # Age secrets for mirror tokens and runner
  age.secrets = builtins.listToAttrs (map (name: {
    name = "forge-mirror-${name}";
    value = {
      file = forgeConfig.mirrors.${name}.tokenFile;
      owner = "forgejo";
      group = "forgejo";
      mode = "0400";
    };
  }) mirrorNames) // {
    forgejo-runner-secret = {
      file = ./runner-secret.age;
      owner = "forgejo";
      group = "forgejo";
      mode = "0400";
    };
  };

  # Credential directories
  systemd.tmpfiles.rules = [
    "d ${authDir} 0700 forgejo forgejo -"
    "d ${bootstrapDir} 0700 forgejo forgejo -"
    "d ${runnerDir} 0750 forgejo forgejo -"
  ];

  # Auto-redirect to OIDC - skip the login page entirely
  services.nginx.virtualHosts."git.${domain}".locations = {
    "= /user/login".return = "302 ${oidcPath}";
  };

  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    settings = {
      server = {
        DOMAIN = "git.${domain}";
        ROOT_URL = "https://git.${domain}/";
        HTTP_PORT = 3001;
      };
      service = {
        DISABLE_REGISTRATION = false;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
      };
      security = {
        PASSWORD_SIGN_IN_DISABLED = true;
      };
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "preferred_username";
        ACCOUNT_LINKING = "auto";
      };
      actions = {
        ENABLED = true;
      };
    };
  };

  # Bootstrap/update OIDC auth source after credentials are delivered
  systemd.services.forgejo-oidc-setup = {
    description = "Configure Forgejo OIDC authentication source";
    after = [ "forgejo.service" ];
    path = [ config.services.forgejo.package pkgs.gawk pkgs.gnugrep pkgs.coreutils ];

    environment = {
      GITEA_WORK_DIR = "/var/lib/forgejo";
      GITEA_CUSTOM = "/var/lib/forgejo/custom";
    };

    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = "/var/lib/forgejo";
      # Restart forgejo after updating auth source
      # --no-block: queue restart without waiting (avoids dependency cycle with requires)
      # + prefix: run as root
      ExecStartPost = "+${pkgs.systemd}/bin/systemctl restart --no-block forgejo.service";
    };

    script = ''
      set -euo pipefail

      # Wait for credentials to be delivered
      if [ ! -s ${authDir}/client-id ] || [ ! -s ${authDir}/client-secret ]; then
        echo "OIDC credentials not yet delivered, skipping setup"
        exit 0
      fi

      CLIENT_ID=$(cat ${authDir}/client-id)
      CLIENT_SECRET=$(cat ${authDir}/client-secret)
      DISCOVER_URL="https://id.${domain}/.well-known/openid-configuration"

      # Check if auth source already exists (forgejo uses gitea binary name)
      EXISTING_ID=$(gitea admin auth list 2>/dev/null | grep -E "^\s*[0-9]+.*Pocket ID" | awk '{print $1}' || true)

      COMMON_OPTS="--name 'Pocket ID' \
        --provider openidConnect \
        --key $CLIENT_ID \
        --secret $CLIENT_SECRET \
        --auto-discover-url $DISCOVER_URL \
        --scopes openid,profile,email,groups \
        --required-claim-name groups \
        --required-claim-value admin \
        --skip-local-2fa"

      if [ -n "$EXISTING_ID" ]; then
        echo "Updating existing OIDC auth source (ID: $EXISTING_ID)"
        eval "gitea admin auth update-oauth --id $EXISTING_ID $COMMON_OPTS"
      else
        echo "Creating new OIDC auth source"
        eval "gitea admin auth add-oauth $COMMON_OPTS"
      fi
    '';
  };

  # Bootstrap org, repo, and push mirrors
  systemd.services.forgejo-bootstrap = {
    description = "Bootstrap Forgejo org, repo, and push mirrors";
    after = [ "forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.forgejo.package pkgs.curl pkgs.jq pkgs.coreutils pkgs.openssl ];

    environment = {
      GITEA_WORK_DIR = "/var/lib/forgejo";
      GITEA_CUSTOM = "/var/lib/forgejo/custom";
      FORGEJO_ORG = forgeConfig.org;
      FORGEJO_REPO = forgeConfig.repo;
    };

    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = "/var/lib/forgejo";
      RemainAfterExit = true;
    };

    script = let
      mirrorSecretPaths = builtins.listToAttrs (map (name: {
        name = name;
        value = config.age.secrets."forge-mirror-${name}".path;
      }) mirrorNames);
      mirrorsJson = builtins.toJSON (lib.mapAttrs (name: cfg: {
        remote = cfg.remote;
        tokenPath = mirrorSecretPaths.${name};
      }) forgeConfig.mirrors);
    in ''
      set -euo pipefail

      API_URL="http://localhost:3001/api/v1"
      TOKEN_FILE="${bootstrapDir}/admin-token"
      ADMIN_USER="forge-admin"

      # Wait for Forgejo to be ready
      for i in $(seq 1 30); do
        if curl -sf "$API_URL/version" > /dev/null 2>&1; then
          break
        fi
        echo "Waiting for Forgejo API..."
        sleep 2
      done

      # Create admin user if not exists
      if ! gitea admin user list 2>/dev/null | grep -q "^[0-9]*[[:space:]]*$ADMIN_USER[[:space:]]"; then
        echo "Creating admin user: $ADMIN_USER"
        ADMIN_PASS=$(openssl rand -base64 32)
        gitea admin user create \
          --username "$ADMIN_USER" \
          --password "$ADMIN_PASS" \
          --email "forge-admin@localhost" \
          --admin \
          --must-change-password=false
      fi

      # Generate access token if not exists
      if [ ! -s "$TOKEN_FILE" ]; then
        echo "Generating admin access token"
        TOKEN=$(gitea admin user generate-access-token \
          --username "$ADMIN_USER" \
          --token-name "bootstrap" \
          --scopes "write:organization,write:repository,write:admin" \
          --raw)
        echo "$TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
      fi
      TOKEN=$(cat "$TOKEN_FILE")

      # Helper for API calls
      api() {
        curl -sf -H "Authorization: token $TOKEN" -H "Content-Type: application/json" "$@"
      }

      # Create org if not exists
      if ! api "$API_URL/orgs/$FORGEJO_ORG" > /dev/null 2>&1; then
        echo "Creating org: $FORGEJO_ORG"
        api -X POST "$API_URL/orgs" -d "{\"username\": \"$FORGEJO_ORG\"}"
      fi

      # Create repo if not exists
      if ! api "$API_URL/repos/$FORGEJO_ORG/$FORGEJO_REPO" > /dev/null 2>&1; then
        echo "Creating repo: $FORGEJO_ORG/$FORGEJO_REPO"
        api -X POST "$API_URL/orgs/$FORGEJO_ORG/repos" \
          -d "{\"name\": \"$FORGEJO_REPO\", \"private\": true}"
      fi

      # Configure push mirrors
      MIRRORS='${mirrorsJson}'
      for mirror_name in $(echo "$MIRRORS" | jq -r 'keys[]'); do
        remote=$(echo "$MIRRORS" | jq -r --arg n "$mirror_name" '.[$n].remote')
        token_path=$(echo "$MIRRORS" | jq -r --arg n "$mirror_name" '.[$n].tokenPath')
        token=$(cat "$token_path")

        # Build mirror URL (credentials passed separately)
        mirror_url="https://$remote.git"

        # Check if mirror already exists
        existing=$(api "$API_URL/repos/$FORGEJO_ORG/$FORGEJO_REPO/push_mirrors" | jq -r --arg r "$remote" '.[] | select(.remote_address | contains($r)) | .id' || true)

        if [ -z "$existing" ]; then
          echo "Adding push mirror: $mirror_name ($remote)"
          api -X POST "$API_URL/repos/$FORGEJO_ORG/$FORGEJO_REPO/push_mirrors" \
            -d "{\"remote_address\": \"$mirror_url\", \"remote_username\": \"x-access-token\", \"remote_password\": \"$token\", \"interval\": \"8h0m0s\", \"sync_on_commit\": true}"
        else
          echo "Push mirror already configured: $mirror_name"
        fi
      done

      # Register runner with Forgejo using shared secret
      RUNNER_SECRET=$(cat ${config.age.secrets.forgejo-runner-secret.path})
      RUNNER_MARKER="${bootstrapDir}/runner-registered"
      if [ ! -f "$RUNNER_MARKER" ]; then
        echo "Registering Actions runner with Forgejo"
        gitea forgejo-cli actions register --secret "$RUNNER_SECRET"
        touch "$RUNNER_MARKER"
      else
        echo "Actions runner already registered"
      fi

      echo "Forgejo bootstrap complete"
    '';
  };

  # Create runner config file using shared secret
  systemd.services.forgejo-runner-register = {
    description = "Create Forgejo Actions runner config";
    after = [ "forgejo-bootstrap.service" ];
    requires = [ "forgejo-bootstrap.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.forgejo-runner ];

    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = runnerDir;
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      # Always ensure config.yml exists with correct labels
      cat > "${runnerDir}/config.yml" <<'EOF'
runner:
  labels:
    - "nixos:host"
EOF

      RUNNER_FILE="${runnerDir}/.runner"
      if [ -f "$RUNNER_FILE" ]; then
        echo "Runner already registered"
        exit 0
      fi

      RUNNER_SECRET=$(cat ${config.age.secrets.forgejo-runner-secret.path})

      echo "Creating runner file"
      forgejo-runner create-runner-file \
        --instance "https://git.${domain}" \
        --secret "$RUNNER_SECRET" \
        --name "forge-runner"

      echo "Runner registered"
    '';
  };

  # Actions runner daemon
  systemd.services.forgejo-runner = {
    description = "Forgejo Actions runner";
    after = [ "network.target" "forgejo-runner-register.service" ];
    requires = [ "forgejo-runner-register.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.forgejo-runner pkgs.bash pkgs.coreutils pkgs.nix pkgs.git pkgs.nodejs ];

    environment = {
      HOME = runnerDir;
    };

    serviceConfig = {
      Type = "simple";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = runnerDir;
      ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon -c ${runnerDir}/config.yml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  fortCluster.exposedServices = [
    {
      name = "git";
      port = 3001;
      visibility = "vpn";
      sso = {
        mode = "oidc";
        restart = "forgejo-oidc-setup.service";
      };
    }
  ];
}
