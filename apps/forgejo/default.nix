{ rootManifest, ... }:
{ config, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  authDir = "/var/lib/fort-auth/git";
in
{
  # Credential directory for OIDC client credentials (delivered by service-registry)
  systemd.tmpfiles.rules = [
    "d ${authDir} 0700 forgejo forgejo -"
  ];

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
        DISABLE_REGISTRATION = true;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
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
    path = [ config.services.forgejo.package ];

    serviceConfig = {
      Type = "oneshot";
      User = "forgejo";
      Group = "forgejo";
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

      # Check if auth source already exists
      EXISTING_ID=$(forgejo admin auth list 2>/dev/null | grep -E "^\s*[0-9]+.*Pocket ID" | awk '{print $1}' || true)

      if [ -n "$EXISTING_ID" ]; then
        echo "Updating existing OIDC auth source (ID: $EXISTING_ID)"
        forgejo admin auth update-oauth \
          --id "$EXISTING_ID" \
          --name "Pocket ID" \
          --provider openidConnect \
          --key "$CLIENT_ID" \
          --secret "$CLIENT_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          --skip-local-2fa
      else
        echo "Creating new OIDC auth source"
        forgejo admin auth add-oauth \
          --name "Pocket ID" \
          --provider openidConnect \
          --key "$CLIENT_ID" \
          --secret "$CLIENT_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          --skip-local-2fa
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
