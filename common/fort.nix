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

                openToLAN = lib.mkOption {
                  type = bool;
                  default = false;
                  description = ''
                    Whether this service should be discoverable on the local
                    network and CoreDNS for non-mesh devices.
                  '';
                };

                openToWAN = lib.mkOption {
                  type = bool;
                  default = false;
                  description = ''
                    Whether this service should be exposed via the VPS reverse proxy
                    and made available publicly.
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
              openToLAN = true;
            }
            {
              name = "immich";
              port = 2283;
              openToLAN = true;
              openToWAN = true;
              subdomain = "photos";
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
          # Whitelist FortMesh addresses
          geo $is_mesh {
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
                  extraConfig = lib.optionalString (!svc.openToLAN) ''
                    if ($is_mesh = 0) {
                      return 444;
                    }
                  '';
                  proxyPass = "http://127.0.0.1:${toString svc.port}";
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
