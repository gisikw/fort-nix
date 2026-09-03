# SSO auth backends (q-d9cba37c)
#
# The auth side of service exposure: per-service oauth2-proxy instances,
# the shared identity-proxy, the njs token-validation secret, and the
# auto-generated oidc-register needs that provision client credentials.
# The nginx locations that route to these backends live in nginx.nix.
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;

  inherit (import ./service-lib.nix) subdomainOf;

  # OIDC credential consumer handler generator - stores client_id and client_secret
  # Takes service name and restart target as parameters
  # Only restarts service if credentials actually changed (avoids session invalidation on redeploy)
  mkOidcHandler =
    serviceName: restartTarget:
    pkgs.writeShellScript "oidc-handler-${serviceName}" ''
      set -euo pipefail

      AUTH_DIR="/var/lib/fort-auth/${serviceName}"

      # Read payload once
      payload=$(${pkgs.coreutils}/bin/cat)

      # Create target directory
      ${pkgs.coreutils}/bin/mkdir -p "$AUTH_DIR"

      # Extract new credentials
      new_client_id=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.client_id')
      new_client_secret=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.client_secret')

      # Read existing credentials (empty string if file doesn't exist)
      old_client_id=""
      old_client_secret=""
      [ -f "$AUTH_DIR/client-id" ] && old_client_id=$(${pkgs.coreutils}/bin/cat "$AUTH_DIR/client-id")
      [ -f "$AUTH_DIR/client-secret" ] && old_client_secret=$(${pkgs.coreutils}/bin/cat "$AUTH_DIR/client-secret")

      # Check if credentials changed
      if [ "$new_client_id" = "$old_client_id" ] && [ "$new_client_secret" = "$old_client_secret" ]; then
        exit 0  # No change, skip write and restart
      fi

      # Store credentials (no trailing newline - oauth2-proxy is sensitive to this)
      ${pkgs.coreutils}/bin/printf '%s' "$new_client_id" > "$AUTH_DIR/client-id"
      ${pkgs.coreutils}/bin/printf '%s' "$new_client_secret" > "$AUTH_DIR/client-secret"

      # Set permissions (readable by service)
      ${pkgs.coreutils}/bin/chmod 644 "$AUTH_DIR/client-id"
      ${pkgs.coreutils}/bin/chmod 600 "$AUTH_DIR/client-secret"

      # Restart the appropriate service
      ${pkgs.systemd}/bin/systemctl restart "${restartTarget}" 2>/dev/null || true
    '';

  # Get services that need OIDC registration (sso.mode not in none/token/identity)
  ssoServices = builtins.filter (
    svc: svc.sso.mode != "none" && svc.sso.mode != "token" && svc.sso.mode != "identity"
  ) config.fort.cluster.services;

  # Get services using bearer token auth
  tokenServices = builtins.filter (svc: svc.sso.mode == "token") config.fort.cluster.services;

  # Get services using identity proxy auth
  identityServices = builtins.filter (svc: svc.sso.mode == "identity") config.fort.cluster.services;
  hasIdentityServices = identityServices != [ ];

  # Identity proxy package
  identity-proxy = import ../../pkgs/identity-proxy { inherit pkgs; };
in
{
  config = lib.mkMerge [
    (lib.mkIf (lib.length config.fort.cluster.services >= 1) {

      systemd.services = lib.mkMerge (
        map (
          svc:
          let
            authProxySock = "/run/fort-auth/${svc.name}.sock";
            envFile = "/var/lib/fort-auth/${svc.name}/oauth2-proxy.env";
            subdomain = subdomainOf svc;
            publicUrl = "https://${subdomain}.${domain}";
          in
          lib.optionalAttrs
            (
              svc.staticRoot == null
              && svc.sso.mode != "none"
              && svc.sso.mode != "oidc"
              && svc.sso.mode != "token"
              && svc.sso.mode != "identity"
            )
            {
              "oauth2-proxy-${svc.name}" = {
                wantedBy = [ "multi-user.target" ];

                serviceConfig = {
                  Restart = "on-failure";
                  RestartSec = "10s";
                  ExecStartPre = pkgs.writeShellScript "ensure-secrets" ''
                    set -euo pipefail
                    mkdir -p /var/lib/fort-auth/${svc.name}

                    if [ ! -s /var/lib/fort-auth/${svc.name}/cookie-secret ]; then
                      echo "Generating default cookie secret for ${svc.name}"
                      head -c32 /dev/urandom > /var/lib/fort-auth/${svc.name}/cookie-secret
                    fi

                    if [ ! -s /var/lib/fort-auth/${svc.name}/client-secret ]; then
                      echo "temporary-client-secret" > /var/lib/fort-auth/${svc.name}/client-secret
                    fi

                    if [ ! -s /var/lib/fort-auth/${svc.name}/client-id ]; then
                      echo "${svc.name}-dummy-client" > /var/lib/fort-auth/${svc.name}/client-id
                    fi

                    cat > ${envFile} <<-EOF
                      OAUTH2_PROXY_CLIENT_ID=$(cat /var/lib/fort-auth/${svc.name}/client-id)
                    EOF
                  '';

                  ExecStart = ''
                    ${pkgs.oauth2-proxy}/bin/oauth2-proxy \
                      --provider=oidc \
                      --oidc-issuer-url=https://id.${domain} \
                      --upstream=http://127.0.0.1:${toString svc.port} \
                      --http-address=unix://${authProxySock} \
                      --redirect-url=${publicUrl}/oauth2/callback \
                      --client-secret-file=/var/lib/fort-auth/${svc.name}/client-secret \
                      --cookie-secret-file=/var/lib/fort-auth/${svc.name}/cookie-secret \
                      --cookie-secure=true \
                      --cookie-samesite=none \
                      --cookie-domain=${subdomain}.${domain} \
                      --cookie-name=_oauth2_proxy_${svc.name} \
                      --skip-auth-regex='^/(favicon\.ico|service_worker\.js|\.client/.*|manifest\.json)$' \
                      --pass-user-headers \
                      --email-domain=* \
                      --skip-provider-button=true \
                      --scope="openid email profile groups" \
                      --oidc-groups-claim=groups \
                      --reverse-proxy=true \
                      ${lib.concatStringsSep " " (map (g: "--allowed-group=" + g) svc.sso.groups)}
                  '';

                  EnvironmentFile = "-${envFile}";
                  Group = "nginx";
                  UMask = "0007";
                  RuntimeDirectory = "fort-auth/${svc.name}";
                  RuntimeDirectoryMode = "0700";
                  StateDirectory = "fort-auth/${svc.name}";
                  StateDirectoryMode = "0700";
                };
              };
            }
        ) config.fort.cluster.services
      );
    })

    # Token auth secret - distributed to hosts with token-mode services
    (lib.mkIf (tokenServices != [ ]) {
      sops.secrets.fort-token-secret = {
        sopsFile = ./token-secret.sops;
        format = "binary";
        path = "/var/lib/fort-auth/token-secret";
        mode = "0440";
        group = "nginx";
      };
    })

    # Identity proxy - one per host for all identity-mode services
    (lib.mkIf hasIdentityServices {
      sops.secrets.identity-proxy-doc = {
        sopsFile = ./identity.toml.sops;
        format = "binary";
        mode = "0440";
        group = "nginx";
      };

      systemd.services.identity-proxy = {
        description = "Fort identity proxy";
        after = [
          "network.target"
          "tailscaled.service"
        ];
        wants = [ "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ config.sops.secrets.identity-proxy-doc.sopsFile ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${identity-proxy}/bin/identity-proxy";
          Restart = "on-failure";
          RestartSec = "2s";
          Group = "nginx";
          UMask = "0007";
          RuntimeDirectory = "identity-proxy";
          RuntimeDirectoryMode = "0750";
          StateDirectory = "identity-proxy";

          Environment = [
            "LISTEN_SOCKET=/run/identity-proxy/identity-proxy.sock"
            "IDENTITY_DOC=${config.sops.secrets.identity-proxy-doc.path}"
            "COOKIE_SIGNING_KEY=/var/lib/identity-proxy/cookie-key"
            "OIDC_CLIENT_ID_FILE=/var/lib/fort-auth/identity-proxy/client-id"
            "OIDC_CLIENT_SECRET_FILE=/var/lib/fort-auth/identity-proxy/client-secret"
            "OIDC_ISSUER=https://id.${domain}"
            "COOKIE_DOMAIN=.${domain}"
            # Native public clients (RFC 8252) allowed to present Bearer JWTs
            # at /validate. Comma-separated audiences.
            "BEARER_AUDIENCES=familiar-desktop"
          ];

          ExecStartPre = pkgs.writeShellScript "identity-proxy-init" ''
            set -euo pipefail
            mkdir -p /var/lib/identity-proxy
            if [ ! -s /var/lib/identity-proxy/cookie-key ]; then
              head -c32 /dev/urandom | base64 > /var/lib/identity-proxy/cookie-key
              chmod 600 /var/lib/identity-proxy/cookie-key
            fi
            # Ensure OIDC credential dir exists with placeholders
            mkdir -p /var/lib/fort-auth/identity-proxy
            if [ ! -s /var/lib/fort-auth/identity-proxy/client-id ]; then
              echo "identity-proxy-pending" > /var/lib/fort-auth/identity-proxy/client-id
            fi
            if [ ! -s /var/lib/fort-auth/identity-proxy/client-secret ]; then
              echo "pending" > /var/lib/fort-auth/identity-proxy/client-secret
            fi
          '';
        };
      };

      # OIDC registration — one need for the whole identity-proxy on this host
      # Wildcard callback URL covers all subdomains on this domain
      fort.host.needs.oidc-register.identity-proxy = {
        from = "drhorrible";
        request = {
          client_name = "identity-proxy-${config.networking.hostName}.${domain}";
          groups = [ ];
          callback_urls = [ "https://*.${domain}/_identity/callback" ];
        };
        handler = mkOidcHandler "identity-proxy" "identity-proxy.service";
        nag = "15m";
      };

      # Native desktop client (RFC 8252 public client). PKCE carries the
      # security; the client id ships baked into the Electron app and only
      # needs to exist on the provider side. Loopback redirects are matched
      # per RFC 8252 §7.3 (http://127.0.0.1/callback, any port) — pocket-id
      # compares redirect URIs by URI-prefix for loopback when it supports
      # native clients; exact-port registration is the fallback.
      fort.host.needs.oidc-register.familiar-desktop = {
        from = "drhorrible";
        request = {
          client_name = "Familiar Desktop";
          # Pin the OIDC client id: the Electron app ships it as a constant
          # (RFC 8252 public client). The provider recreates the client under
          # this id if an earlier registration minted a random one.
          client_id = "familiar-desktop";
          groups = [ ];
          callback_urls = [ "http://127.0.0.1/callback" ];
        };
        # No service consumes these credentials — the client is public and
        # the id is a constant. The handler records them under fort-auth so
        # re-registration is a no-op rather than a churn of throwaway creds.
        handler = mkOidcHandler "familiar-desktop" "";
        nag = "15m";
      };
    })

    # OIDC needs - auto-generated for services with SSO enabled
    # Each service with sso.mode != "none" gets an oidc need
    (lib.mkIf (ssoServices != [ ]) {
      fort.host.needs.oidc-register = lib.listToAttrs (
        map (
          svc:
          let
            subdomain = subdomainOf svc;
            fqdn = "${subdomain}.${domain}";
            # Default restart target is oauth2-proxy, unless service specifies custom restart
            restartTarget =
              if svc.sso.restart != null then svc.sso.restart else "oauth2-proxy-${svc.name}.service";
          in
          {
            name = svc.name;
            value = {
              from = "drhorrible"; # pocket-id host
              request = {
                client_name = fqdn;
                groups = svc.sso.groups; # LDAP groups allowed to access this client
              };
              handler = mkOidcHandler svc.name restartTarget;
              nag = "15m";
            };
          }
        ) ssoServices
      );
    })
  ];
}
