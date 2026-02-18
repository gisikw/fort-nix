{ subdomain ? null, rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  forgeConfig = rootManifest.fortConfig.forge;
  authDir = "/var/lib/fort-auth/git";
  oidcPath = "/user/oauth2/Pocket%20ID";
  bootstrapDir = "/var/lib/forgejo/bootstrap";
  runnerDir = "/var/lib/forgejo-runner";
  repoNames = builtins.attrNames forgeConfig.repos;

  # Collect all mirrors across all repos as flat list: [{repo, mirror, tokenFile}, ...]
  allMirrors = lib.flatten (map (repoName:
    let repo = forgeConfig.repos.${repoName};
    in map (mirrorName: {
      repo = repoName;
      mirror = mirrorName;
      tokenFile = repo.mirrors.${mirrorName}.tokenFile;
      remote = repo.mirrors.${mirrorName}.remote;
    }) (builtins.attrNames (repo.mirrors or {}))
  ) repoNames);

  # Git token provider (Go handler)
  gitTokenProvider = import ./provider {
    inherit pkgs;
    forgejoPackage = config.services.forgejo.package;
  };

  # Runtime package provider (Go handler)
  runtimePackageProvider = import ./provider/runtime {
    inherit pkgs;
  };

  # Runtime package register handler (Go handler)
  runtimePackageRegister = import ./provider/runtime-register {
    inherit pkgs;
  };

  # Fort CLI for CI to trigger refresh
  fortCli = import ../../pkgs/fort { inherit pkgs domain; };

  # Attic CI token location (created by attic bootstrap)
  atticCiToken = "/var/lib/forgejo-runner/attic-ci-token";
  atticCacheUrl = "https://cache.${domain}";
in
{
  # Age secrets for mirror tokens (per repo-mirror pair) and runner
  age.secrets = builtins.listToAttrs (map (m: {
    name = "forge-mirror-${m.repo}-${m.mirror}";
    value = {
      file = m.tokenFile;
      owner = "forgejo";
      group = "forgejo";
      mode = "0400";
    };
  }) allMirrors) // {
    forgejo-runner-secret = {
      file = ./runner-secret.age;
      owner = "forgejo";
      group = "forgejo";
      mode = "0400";
    };
    ci-agent-key = {
      file = ./ci-agent-key.age;
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

  # Runner needs PTY access for tests that spawn subprocesses
  users.users.forgejo.extraGroups = [ "tty" ];

  # Bootstrap/update OIDC auth source after credentials are delivered
  systemd.services.forgejo-oidc-setup = {
    description = "Configure Forgejo OIDC authentication source";
    after = [ "forgejo.service" ];
    path = [ config.services.forgejo.package pkgs.gawk pkgs.gnugrep pkgs.coreutils pkgs.sudo ];

    environment = {
      GITEA_WORK_DIR = "/var/lib/forgejo";
      GITEA_CUSTOM = "/var/lib/forgejo/custom";
    };

    serviceConfig = {
      Type = "oneshot";
      # Run as root to read credentials, forgejo commands run via sudo -u forgejo
      WorkingDirectory = "/var/lib/forgejo";
      # Restart forgejo after updating auth source
      # --no-block: queue restart without waiting (avoids dependency cycle with requires)
      ExecStartPost = "${pkgs.systemd}/bin/systemctl restart --no-block forgejo.service";
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

      # Run forgejo commands as forgejo user, preserving environment
      run_forgejo() {
        sudo -u forgejo -E HOME=/var/lib/forgejo forgejo "$@"
      }

      # Check if auth source already exists
      EXISTING_ID=$(run_forgejo admin auth list 2>/dev/null | grep -E "^\s*[0-9]+.*Pocket ID" | awk '{print $1}' || true)

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
        eval "run_forgejo admin auth update-oauth --id $EXISTING_ID $COMMON_OPTS"
      else
        echo "Creating new OIDC auth source"
        eval "run_forgejo admin auth add-oauth $COMMON_OPTS"
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
    };

    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
      WorkingDirectory = "/var/lib/forgejo";
      RemainAfterExit = true;
    };

    script = let
      # Build JSON structure: { repoName: { mirrors: { mirrorName: {remote, tokenPath} } } }
      reposJson = builtins.toJSON (lib.mapAttrs (repoName: repoCfg: {
        mirrors = lib.mapAttrs (mirrorName: mirrorCfg: {
          remote = mirrorCfg.remote;
          tokenPath = config.age.secrets."forge-mirror-${repoName}-${mirrorName}".path;
        }) (repoCfg.mirrors or {});
      }) forgeConfig.repos);
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
      if ! forgejo admin user list 2>/dev/null | grep -q "^[0-9]*[[:space:]]*$ADMIN_USER[[:space:]]"; then
        echo "Creating admin user: $ADMIN_USER"
        ADMIN_PASS=$(openssl rand -base64 32)
        forgejo admin user create \
          --username "$ADMIN_USER" \
          --password "$ADMIN_PASS" \
          --email "forge-admin@localhost" \
          --admin \
          --must-change-password=false
      fi

      # Generate access token if not exists
      if [ ! -s "$TOKEN_FILE" ]; then
        echo "Generating admin access token"
        TOKEN=$(forgejo admin user generate-access-token \
          --username "$ADMIN_USER" \
          --token-name "bootstrap" \
          --scopes "write:organization,write:repository,write:admin,write:user" \
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

      # Process each repo
      REPOS='${reposJson}'
      for repo_name in $(echo "$REPOS" | jq -r 'keys[]'); do
        # Create repo if not exists
        if ! api "$API_URL/repos/$FORGEJO_ORG/$repo_name" > /dev/null 2>&1; then
          echo "Creating repo: $FORGEJO_ORG/$repo_name"
          api -X POST "$API_URL/orgs/$FORGEJO_ORG/repos" \
            -d "{\"name\": \"$repo_name\", \"private\": true}"
        fi

        # For repos with GitHub mirrors, ensure the GitHub repo exists (created as private)
        for mirror_name in $(echo "$REPOS" | jq -r --arg r "$repo_name" '.[$r].mirrors | keys[]'); do
          remote=$(echo "$REPOS" | jq -r --arg r "$repo_name" --arg m "$mirror_name" '.[$r].mirrors[$m].remote')
          token_path=$(echo "$REPOS" | jq -r --arg r "$repo_name" --arg m "$mirror_name" '.[$r].mirrors[$m].tokenPath')
          token=$(cat "$token_path")

          if [ "$mirror_name" = "github" ]; then
            gh_owner=$(echo "$remote" | cut -d/ -f1)
            gh_repo=$(echo "$remote" | cut -d/ -f2)
            if ! curl -sf -H "Authorization: token $token" \
                 "https://api.github.com/repos/$gh_owner/$gh_repo" > /dev/null 2>&1; then
              echo "Creating GitHub repo: $gh_owner/$gh_repo (private)"
              curl -sf -X POST -H "Authorization: token $token" \
                -H "Content-Type: application/json" \
                "https://api.github.com/user/repos" \
                -d "{\"name\": \"$gh_repo\", \"private\": true}" > /dev/null
            fi
          fi
        done

        # Configure push mirrors (skip fort-nix - uses CI-gated mirroring)
        if [ "$repo_name" != "fort-nix" ]; then
          for mirror_name in $(echo "$REPOS" | jq -r --arg r "$repo_name" '.[$r].mirrors | keys[]'); do
            remote=$(echo "$REPOS" | jq -r --arg r "$repo_name" --arg m "$mirror_name" '.[$r].mirrors[$m].remote')
            token_path=$(echo "$REPOS" | jq -r --arg r "$repo_name" --arg m "$mirror_name" '.[$r].mirrors[$m].tokenPath')
            token=$(cat "$token_path")

            # Use separate auth fields (Forgejo rejects credentials embedded in URL)
            mirror_url="https://$remote.git"

            existing=$(api "$API_URL/repos/$FORGEJO_ORG/$repo_name/push_mirrors" | jq -r --arg r "$remote" '.[] | select(.remote_address | contains($r)) | .id' || true)

            if [ -z "$existing" ]; then
              echo "Adding push mirror to $repo_name: $mirror_name ($remote)"
              api -X POST "$API_URL/repos/$FORGEJO_ORG/$repo_name/push_mirrors" \
                -d "{\"remote_address\": \"$mirror_url\", \"remote_username\": \"$token\", \"remote_password\": \"\", \"interval\": \"8h0m0s\", \"sync_on_commit\": true}"
            else
              echo "Push mirror already configured for $repo_name: $mirror_name"
            fi
          done
        fi
      done

      # Register runner with Forgejo using shared secret
      RUNNER_SECRET=$(cat ${config.age.secrets.forgejo-runner-secret.path})
      RUNNER_MARKER="${bootstrapDir}/runner-registered"
      if [ ! -f "$RUNNER_MARKER" ]; then
        echo "Registering Actions runner with Forgejo"
        forgejo forgejo-cli actions register --secret "$RUNNER_SECRET"
        touch "$RUNNER_MARKER"
      else
        echo "Actions runner already registered"
      fi

      # Create read-only deploy token for GitOps (comin)
      DEPLOY_TOKEN_FILE="${bootstrapDir}/deploy-token"
      if [ ! -s "$DEPLOY_TOKEN_FILE" ]; then
        echo "Creating deploy token for GitOps"
        DEPLOY_TOKEN=$(forgejo admin user generate-access-token \
          --username "$ADMIN_USER" \
          --token-name "gitops-deploy" \
          --scopes "read:repository" \
          --raw)
        echo "$DEPLOY_TOKEN" > "$DEPLOY_TOKEN_FILE"
        chmod 600 "$DEPLOY_TOKEN_FILE"
        echo "Deploy token created"
      else
        echo "Deploy token already exists"
      fi

      # Create read/write token for dev-sandbox hosts
      DEV_TOKEN_FILE="${bootstrapDir}/dev-token"
      if [ ! -s "$DEV_TOKEN_FILE" ]; then
        echo "Creating dev token for dev-sandbox hosts"
        DEV_TOKEN=$(forgejo admin user generate-access-token \
          --username "$ADMIN_USER" \
          --token-name "dev-sandbox" \
          --scopes "read:repository,write:repository" \
          --raw)
        echo "$DEV_TOKEN" > "$DEV_TOKEN_FILE"
        chmod 600 "$DEV_TOKEN_FILE"
        echo "Dev token created"
      else
        echo "Dev token already exists"
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

      # Runner config with labels and PATH for workflow jobs.
      # PATH must be in config.yml envs (not systemd environment) - jobs don't inherit daemon env.
      # Required tools: bash/coreutils (shell), nix (flake ops), git (checkout),
      # nodejs (JS-based actions like actions/checkout), gnutar/gzip (artifacts),
      # fort (control plane), attic-client (binary cache).
      cat > "${runnerDir}/config.yml" <<EOF
runner:
  labels:
    - "nixos:host"
  envs:
    PATH: "${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.gnused pkgs.nix pkgs.git pkgs.gnutar pkgs.gzip pkgs.nodejs pkgs.jq pkgs.age pkgs.attic-client fortCli ]}"
    FORT_SSH_KEY: "${config.age.secrets.ci-agent-key.path}"
    FORT_ORIGIN: "ci"
    ATTIC_TOKEN_FILE: "${atticCiToken}"
    ATTIC_CACHE_URL: "${atticCacheUrl}"
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

  fort.cluster.services = [
    {
      name = "git";
      subdomain = subdomain;
      port = 3001;
      visibility = "public";
      sso = {
        mode = "oidc";
        restart = "forgejo-oidc-setup.service";
      };
    }
  ];

  # Expose git-token capability for on-demand token generation
  fort.host.capabilities.git-token = {
    handler = "${gitTokenProvider}/bin/git-token-provider";
    mode = "async";
    format = "symmetric";  # Go handler uses symmetric input/output format
    description = "Generate Forgejo deploy tokens on-demand";
  };

  # Expose runtime-package capability for distributing CI-built store paths
  fort.host.capabilities.runtime-package = {
    handler = "${runtimePackageProvider}/bin/runtime-package-provider";
    mode = "async";
    format = "symmetric";  # Go handler uses symmetric input/output format
    description = "Distribute runtime package store paths from CI builds";
  };

  # Expose runtime-package-register capability for CI to register built packages
  fort.host.capabilities.runtime-package-register = {
    handler = "${runtimePackageRegister}/bin/runtime-register";
    mode = "rpc";  # Simple request-response, no state tracking
    description = "Register runtime package store paths from CI builds";
    allowed = [ "ci" ];  # Only CI can register packages
  };
}
