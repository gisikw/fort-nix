{ rootManifest, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  options.fort.cluster = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.attrsOf lib.types.anything;
      options = {
        services = lib.mkOption {
          type =
            with lib.types;
            listOf (submodule {
              options = {
                name = lib.mkOption {
                  type = str;
                  description = "Logical service name (used for default subdomain).";
                  example = "jellyfin";
                };

                subdomain = lib.mkOption {
                  type = nullOr str;
                  default = null;
                  description = ''
                    Optional subdomain override.  
                    Defaults to `name` if unset, allowing you to distinguish between
                    service naming and public routing (e.g., observability stacks).
                  '';
                  example = "movies";
                };

                port = lib.mkOption {
                  type = int;
                  description = "Internal port where the service listens.";
                  example = 8096;
                };

                inEgressNamespace = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether this service runs inside the egress-vpn namespace";
                };

                maxBodySize = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "nginx client_max_body_size for this service (e.g., '2G' for large uploads)";
                  example = "2G";
                };

                visibility = lib.mkOption {
                  type = lib.types.enum [ "vpn" "local" "public" ];
                  default = "vpn";
                  description = ''
                    The visibility level for this service.
                    Defaults to `vpn`, with nginx rejecting non-VPN traffic to the subdomain.
                    `local` removes the source restriction and adds local CoreDNS record.
                    `public` instantiates a reverse-proxy for the service on the beacon box.
                  '';
                };

                sso = lib.mkOption {
                  type = lib.types.submodule {
                    options = {
                      mode = lib.mkOption {
                        type = lib.types.enum [ "none" "oidc" "headers" "basicauth" "gatekeeper" ];
                        default = "none";
                        description = ''
                          SSO handling mode for this service:
                          - `none`: no authentication, plain reverse proxy.
                          - `oidc`: provision an oidc client, delivering credentials to /var/lib/fort-auth/<service>
                          - `headers`: inject X-Auth-* headers from oauth2-proxy.
                          - `basicauth`: translate auth into BasicAuth credentials for backend.
                          - `gatekeeper`: enforce login but do not inject identity.
                        '';
                      };

                      restart = lib.mkOption {
                        type = nullOr str;
                        default = null;
                        description = ''
                          Name of the systemd service to restart after OIDC credentials are delivered.
                        '';
                      };

                      groups = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                        description = ''
                          Optional list of allowed LDAP/SSO groups. Only these users may access.
                          Passed through to oauth2-proxy as `--allowed-group`.
                        '';
                      };
                    };
                  };

                  default = { };
                };
              };
            });
          default = [ ];
          description = "List of service exposure declarations for Nginx/DNS/etc.";
          example = [
            {
              name = "jellyfin";
              port = 8096;
              visibility = "local";
            }
            {
              name = "immich";
              port = 2283;
              subdomain = "photos";
              visibility = "public";
            }
          ];
        };
      };
    };
    default = { };
    description = "Cluster-level configuration and service exposure registry.";
  };

  config = lib.mkMerge [
    # VPN geo block - always defined so aspects (like host-status) can use it
    {
      services.nginx.commonHttpConfig = lib.mkBefore ''
        geo $is_vpn {
          default 0;
          100.64.0.0/10 1;
        }
      '';
    }

    (lib.mkIf (lib.length config.fort.cluster.services >= 1) {

      systemd.services = lib.mkMerge (map (svc:
        let
          authProxySock = "/run/fort-auth/${svc.name}.sock";
          envFile = "/var/lib/fort-auth/${svc.name}/oauth2-proxy.env";
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
                  --client-secret-file=/var/lib/fort-auth/${svc.name}/client-secret \
                  --cookie-secret-file=/var/lib/fort-auth/${svc.name}/cookie-secret \
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
            in
            {
              name = "${subdomain}.${domain}";
              value = {
                forceSSL = true;
                sslCertificate = "/var/lib/fort/ssl/${domain}/fullchain.pem";
                sslCertificateKey = "/var/lib/fort/ssl/${domain}/key.pem";
                locations."/" = {
                  extraConfig = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
                    (lib.optionalString (svc.visibility == "vpn") ''
                      if ($is_vpn = 0) {
                        return 444;
                      }
                    '')
                    (lib.optionalString (svc.maxBodySize != null) ''
                      client_max_body_size ${svc.maxBodySize};
                    '')
                  ]);
                  proxyPass = if (svc.sso.mode != "none" && svc.sso.mode != "oidc") then
                    "http://unix:/run/fort-auth/${svc.name}.sock"
                  else
                    "http://${if svc.inEgressNamespace then "10.200.0.2" else "127.0.0.1"}:${toString svc.port}";
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
  ];
}
