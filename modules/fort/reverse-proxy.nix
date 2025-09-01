{ lib, fort, config, ... }:

{
  options.fort.routes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        subdomain = lib.mkOption {
          type = lib.types.str;
          description = "Subdomain to route to this service.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Target port for the reverse proxy.";
        };
      };
    });
    default = {};
    description = "Declared reverse proxy routes for this host.";
  };

  config = {
    networking.firewall.allowedTCPPorts = [ 80 443 ];
    services.nginx = {
      enable = true;
      commonHttpConfig = ''
        server_names_hash_bucket_size 128;
      '';
      virtualHosts = lib.mapAttrs (name: route: {
        serverName = "${route.subdomain}.${fort.settings.domain}";

        enableACME = false;
        forceSSL = true;
        useACMEHost = null;

        sslCertificate = "/etc/ssl/${fort.settings.domain}/fullchain.pem";
        sslCertificateKey = "/etc/ssl/${fort.settings.domain}/key.pem";

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString route.port}";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
          '';
        };
      }) config.fort.routes;
    };

    systemd.services.nginx = {
      serviceConfig = {
        ConditionPathExists = [
          "/etc/ssl/${fort.settings.domain}/fullchain.pem"
          "/etc/ssl/${fort.settings.domain}/key.pem"
        ];
      };
    };
  };
}
