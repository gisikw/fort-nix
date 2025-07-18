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
      virtualHosts = lib.mapAttrs (name: route: {
        serverName = "${route.subdomain}.${fort.settings.domain}";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString route.port}";
        };
      }) config.fort.routes;
    };
  };
}
