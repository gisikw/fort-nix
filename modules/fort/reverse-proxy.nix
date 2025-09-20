{ lib, fort, config, pkgs, ... }:

{
  options.fort.routes = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        subdomain = lib.mkOption {
          type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
          description = "Subdomain(s) to route to this service. Can be a string or a list of strings.";
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

  config =
    let
      domain = fort.settings.domain;
      tailscaleServePort = 41137;
      toList = value: if builtins.isList value then value else [ value ];
      routes = lib.mapAttrsToList (name: route:
        let
          subdomains = toList route.subdomain;
        in
        {
          inherit name;
          port = route.port;
          subdomains = subdomains;
          hostnames = map (s: "${s}.${domain}") subdomains;
        }
      ) config.fort.routes;
      servicesManifest = {
        host = fort.host;
        domain = domain;
        tailnetHost = "${fort.host}.tail.${domain}";
        tailscaleServe = {
          port = tailscaleServePort;
          scheme = "http";
          path = "/";
        };
        routes = routes;
      };
      servicesJson = builtins.toJSON servicesManifest;
      servicesJsonStorePath = pkgs.writeText "fort-services.json" servicesJson;
      tailscaleBin = lib.getExe config.services.tailscale.package;
    in
  {
    networking.firewall.allowedTCPPorts = [ 80 443 ];
    services.nginx = {
      enable = true;
      commonHttpConfig = ''
        server_names_hash_bucket_size 128;
      '';
      virtualHosts = lib.recursiveUpdate
        {
          "000-default" = {
            default = true;
            listen = [
              { addr = "0.0.0.0"; port = 80; ssl = false; }
              { addr = "0.0.0.0"; port = 443; ssl = true; }
            ];
            extraConfig = ''
              return 444;
              ssl_certificate /etc/ssl/${fort.settings.domain}/fullchain.pem;
              ssl_certificate_key /etc/ssl/${fort.settings.domain}/key.pem;
            '';
          };
        }
        (lib.mapAttrs (name: route: {
          serverName =
            if builtins.isString route.subdomain then
              "${route.subdomain}.${fort.settings.domain}"
            else
              builtins.concatStringsSep " " (map (s: "${s}.${fort.settings.domain}") route.subdomain);

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
        }) config.fort.routes);
    };

    systemd.services.nginx.unitConfig.ConditionPathExists = [
      "/etc/ssl/${fort.settings.domain}/fullchain.pem"
      "/etc/ssl/${fort.settings.domain}/key.pem"
    ];

    systemd.tmpfiles.rules = lib.mkAfter [
      "d /var/lib/fort 0755 root root -"
    ];

    systemd.services.fort-write-services-json = {
      description = "Generate fort services manifest";
      wantedBy = [ "multi-user.target" ];
      partOf = [ "nginx.service" ];
      restartTriggers = [ servicesJsonStorePath ];
      serviceConfig = {
        Type = "oneshot";
      };
      path = [ pkgs.coreutils ];
      script = ''
        install -Dm0644 ${servicesJsonStorePath} /var/lib/fort/services.json
      '';
    };

    systemd.services.fort-tailscale-serve = lib.mkIf config.services.tailscale.enable {
      description = "Expose fort services manifest over tailscale serve";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tailscaled.service"
        "fort-write-services-json.service"
      ] ++ lib.optional (config.systemd.services ? tailscaled-autoconnect) "tailscaled-autoconnect.service";
      requires = [ "tailscaled.service" "fort-write-services-json.service" ];
      path = [ config.services.tailscale.package pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${tailscaleBin} serve --http=${toString tailscaleServePort} /var/lib/fort
      '';
    };
  };
}
