{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  vpnIpv4Prefix = rootManifest.fortConfig.settings.vpn.ipv4Prefix;

  # SSL cert consumer handler - decodes base64 certs and stores them
  sslCertConsumerHandler = pkgs.writeShellScript "ssl-cert-handler" ''
    set -euo pipefail

    # Read payload once
    payload=$(${pkgs.coreutils}/bin/cat)

    # Create target directory
    mkdir -p /var/lib/fort/ssl/${domain}

    # Decode and store certs from JSON payload
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.cert' | ${pkgs.coreutils}/bin/base64 -d > /var/lib/fort/ssl/${domain}/fullchain.pem
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.key' | ${pkgs.coreutils}/bin/base64 -d > /var/lib/fort/ssl/${domain}/key.pem
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.chain' | ${pkgs.coreutils}/bin/base64 -d > /var/lib/fort/ssl/${domain}/chain.pem

    # Set permissions
    chown -R root:root /var/lib/fort/ssl
    chmod -R u=rwX,go=rX /var/lib/fort/ssl

    # Reload nginx if running
    ${pkgs.systemd}/bin/systemctl reload nginx 2>/dev/null || true
  '';

  # OIDC credential consumer handler generator - stores client_id and client_secret
  # Takes service name and restart target as parameters
  # Only restarts service if credentials actually changed (avoids session invalidation on redeploy)
  mkOidcHandler = serviceName: restartTarget: pkgs.writeShellScript "oidc-handler-${serviceName}" ''
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

  # Get services that need OIDC registration (sso.mode != "none")
  ssoServices = builtins.filter (svc: svc.sso.mode != "none") config.fort.cluster.services;

  # Check if this host is the OIDC provider (has pocket-id)
  isOidcProvider = builtins.any (svc: svc.name == "pocket-id") config.fort.cluster.services;

  # Check if this host is the certificate provider (has ACME certs configured)
  isCertProvider = config.security.acme.certs ? ${domain};

  # Discover beacon host for proxy needs
  beaconHost = let
    hostFiles = builtins.readDir cluster.hostsDir;
    hosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
    beacons = builtins.filter (h: builtins.elem "beacon" h.roles) (builtins.attrValues hosts);
  in if beacons != [] then (builtins.head beacons).hostName else null;

  # Discover forge host for LAN DNS needs
  forgeHost = let
    hostFiles = builtins.readDir cluster.hostsDir;
    hosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
    forges = builtins.filter (h: builtins.elem "forge" h.roles) (builtins.attrValues hosts);
  in if forges != [] then (builtins.head forges).hostName else null;

  # Check if this host is the proxy provider (beacon)
  isProxyProvider = beaconHost == config.networking.hostName;

  # Get services that need public proxy configuration
  publicServices = builtins.filter (svc: svc.visibility == "public") config.fort.cluster.services;

  # Get services that need LAN DNS (non-vpn visibility)
  lanDnsServices = builtins.filter (svc: svc.visibility != "vpn") config.fort.cluster.services;
in
{
  # fort.cluster options are declared in fort-options.nix (shared with darwin builder)

  config = lib.mkMerge [
    # VPN geo block - always defined so aspects (like host-status) can use it
    # Also configure realip to trust X-Real-IP from VPN (beacon proxy)
    {
      services.nginx.commonHttpConfig = lib.mkBefore ''
        # Trust X-Real-IP header from VPN peers (beacon proxy)
        set_real_ip_from ${vpnIpv4Prefix};
        real_ip_header X-Real-IP;
        real_ip_recursive on;

        geo $is_vpn {
          default 0;
          ${vpnIpv4Prefix} 1;
        }
      '';
    }

    (lib.mkIf (lib.length config.fort.cluster.services >= 1) {

      systemd.services = lib.mkMerge (map (svc:
        let
          authProxySock = "/run/fort-auth/${svc.name}.sock";
          envFile = "/var/lib/fort-auth/${svc.name}/oauth2-proxy.env";
          subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
          publicUrl = "https://${subdomain}.${domain}";
        in lib.optionalAttrs (svc.sso.mode != "none" && svc.sso.mode != "oidc") {
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
                  --cookie-samesite=lax \
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
      ) config.fort.cluster.services);

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;

        virtualHosts = lib.listToAttrs (
          map (
            svc:
            let
              subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
              needsAuthProxy = svc.sso.mode != "none" && svc.sso.mode != "oidc";
              directBackend = "http://${if svc.inEgressNamespace then "10.200.0.2" else "127.0.0.1"}:${toString svc.port}";
              authProxySocket = "http://unix:/run/fort-auth/${svc.name}.sock";
            in
            {
              name = "${subdomain}.${domain}";
              value = {
                forceSSL = true;
                sslCertificate = "/var/lib/fort/ssl/${domain}/fullchain.pem";
                sslCertificateKey = "/var/lib/fort/ssl/${domain}/key.pem";
                locations."/" = {
                  extraConfig = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
                    # Ensure cookies are forwarded (not included in recommendedProxySettings)
                    "proxy_set_header Cookie $http_cookie;"
                    (lib.optionalString (svc.visibility == "vpn") ''
                      if ($is_vpn = 0) {
                        return 444;
                      }
                    '')
                    (lib.optionalString (svc.maxBodySize != null) ''
                      client_max_body_size ${svc.maxBodySize};
                    '')
                    # Conditional routing: VPN bypasses auth, non-VPN goes through oauth2-proxy
                    # When proxyPass is null, NixOS doesn't add recommended headers, so we must add them
                    (lib.optionalString (svc.sso.vpnBypass && needsAuthProxy) ''
                      proxy_set_header Host $host;
                      proxy_set_header X-Real-IP $remote_addr;
                      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto $scheme;
                      proxy_set_header X-Forwarded-Host $host;
                      proxy_set_header X-Forwarded-Server $host;
                      set $backend "${authProxySocket}";
                      if ($is_vpn = 1) {
                        set $backend "${directBackend}";
                      }
                      proxy_pass $backend;
                    '')
                  ]);
                  # Only set proxyPass when not using vpnBypass conditional routing
                  proxyPass = if (svc.sso.vpnBypass && needsAuthProxy) then
                    null
                  else if needsAuthProxy then
                    authProxySocket
                  else
                    directBackend;
                  proxyWebsockets = true;
                };
              };
            }
          ) config.fort.cluster.services
        );
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    })

    # Write unified host manifest for service discovery
    {
      system.activationScripts.fortHostManifest.text = let
        # Extract aspect names (handle both string and {name=...} forms)
        aspectName = a: if builtins.isString a then a else a.name or "unknown";
        hostManifestJson = builtins.toFile "host-manifest.json" (builtins.toJSON {
          apps = config.fort.host.apps or [];
          aspects = map aspectName (config.fort.host.aspects or []);
          roles = config.fort.host.roles or [];
          services = config.fort.cluster.services;
        });
      in ''
        install -Dm0644 ${hostManifestJson} /var/lib/fort/host-manifest.json
      '';
    }

    # SSL certificate need - all hosts with nginx that aren't the cert provider
    (lib.mkIf (config.services.nginx.enable && !isCertProvider) {
      fort.host.needs.ssl-cert.default = {
        from = "drhorrible";  # certificate-broker host
        request = {};
        handler = sslCertConsumerHandler;
        nag = "1h";  # Re-request if certs not received within 1h
      };
    })

    # OIDC needs - auto-generated for services with SSO enabled
    # Each service with sso.mode != "none" gets an oidc need
    (lib.mkIf (ssoServices != []) {
      fort.host.needs.oidc-register = lib.listToAttrs (map (svc:
        let
          subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
          fqdn = "${subdomain}.${domain}";
          # Default restart target is oauth2-proxy, unless service specifies custom restart
          restartTarget = if svc.sso.restart != null
            then svc.sso.restart
            else "oauth2-proxy-${svc.name}.service";
        in {
          name = svc.name;
          value = {
            from = "drhorrible";  # pocket-id host
            request = {
              client_name = fqdn;
              groups = svc.sso.groups;  # LDAP groups allowed to access this client
            };
            handler = mkOidcHandler svc.name restartTarget;
            nag = "15m";
          };
        }
      ) ssoServices);
    })

    # Proxy needs - auto-generated for public services
    # Each public service gets a proxy need to configure beacon's nginx
    (lib.mkIf (publicServices != [] && !isProxyProvider && beaconHost != null) {
      fort.host.needs.proxy = lib.listToAttrs (map (svc:
        let
          subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = beaconHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need
          };
        }
      ) publicServices);
    })

    # DNS (Headscale) needs - auto-generated for all services
    # Each service gets a dns-headscale need so it can be resolved over the VPN mesh
    (lib.mkIf (config.fort.cluster.services != [] && beaconHost != null) {
      fort.host.needs.dns-headscale = lib.listToAttrs (map (svc:
        let
          subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = beaconHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need (provider writes extra-records.json)
          };
        }
      ) config.fort.cluster.services);
    })

    # DNS (CoreDNS) needs - auto-generated for non-vpn services
    # Each non-vpn service gets a dns-coredns need so it can be resolved on the LAN
    (lib.mkIf (lanDnsServices != [] && forgeHost != null) {
      fort.host.needs.dns-coredns = lib.listToAttrs (map (svc:
        let
          subdomain = if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
          fqdn = "${subdomain}.${domain}";
        in {
          name = svc.name;
          value = {
            from = forgeHost;
            request = {
              inherit fqdn;
            };
            nag = "1h";
            # No handler - side-effect-only need (provider writes custom.conf)
          };
        }
      ) lanDnsServices);
    })
  ];
}
