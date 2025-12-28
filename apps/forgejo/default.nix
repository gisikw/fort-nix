{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  authDir = "/var/lib/fort-auth/git";
  oidcPath = "/user/oauth2/Pocket%20ID";
in
{
  # Credential directory for OIDC client credentials (delivered by service-registry)
  systemd.tmpfiles.rules = [
    "d ${authDir} 0700 forgejo forgejo -"
  ];

  # Auto-redirect to OIDC for unauthenticated users
  services.nginx.virtualHosts."git.${domain}".locations = {
    "= /".extraConfig = ''
      if ($cookie_session = "") {
        return 302 ${oidcPath};
      }
      proxy_pass http://127.0.0.1:3001;
      proxy_set_header Host $host;
    '';
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
    };
  };

  # Bootstrap/update OIDC auth source after credentials are delivered
  systemd.services.forgejo-oidc-setup = {
    description = "Configure Forgejo OIDC authentication source";
    after = [ "forgejo.service" ];
    requires = [ "forgejo.service" ];
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
      # Restart forgejo after updating auth source (+ prefix runs as root)
      ExecStartPost = "+${pkgs.systemd}/bin/systemctl restart forgejo.service";
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
