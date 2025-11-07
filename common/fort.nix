{ rootManifest, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  servicesJson = builtins.toFile "services.json" (builtins.toJSON config.fortCluster.exposedServices);
in
{
  options.fortCluster = lib.mkOption {
    type = lib.types.submodule {
      options = {
        exposedServices = lib.mkOption {
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
    (lib.mkIf (lib.length config.fortCluster.exposedServices >= 1) {
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;

        commonHttpConfig = ''
          # Whitelist VPN addresses
          geo $is_vpn {
            default 0;
            100.64.0.0/10 1;
          }
        '';

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
                  extraConfig = lib.optionalString (svc.visibility == "vpn") ''
                    if ($is_vpn = 0) {
                      return 444;
                    }
                  '';
                  proxyPass = "http://${if svc.inEgressNamespace then "10.200.0.2" else "127.0.0.1"}:${toString svc.port}";
                  proxyWebsockets = true;
                };
              };
            }
          ) config.fortCluster.exposedServices
        );
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    })

    {
      system.activationScripts.fortServices.text = ''
        install -Dm0640 ${servicesJson} /var/lib/fort/services.json
      '';
    }
  ];
}
