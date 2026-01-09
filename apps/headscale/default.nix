{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
in
{
  config = lib.mkMerge [
    (lib.mkIf (config.services.tailscale.enable or false) {
      systemd.services.tailscaled = {
        after = [ "headscale.service" ];
        requires = [ "headscale.service" ];
      };
    })
    {
      # Ensure nginx waits for headscale at boot to avoid 502s
      systemd.services.nginx.after = [ "headscale.service" ];
    }
    {
      systemd.tmpfiles.rules = [
        "f /var/lib/headscale/extra-records.json 0640 headscale headscale -"
      ];

      services.headscale = {
        enable = true;
        address = "127.0.0.1";
        port = 9080;
        settings = {
          server_url = "https://mesh.${fort.settings.domain}";
          listen_addr = "127.0.0.1:9080";
          metrics_listen_addr = "127.0.0.1:9090";
          grpc_listen_addr = "127.0.0.1:50443";
          grpc_allow_insecure = true;

          noise.private_key_path = "/var/lib/headscale/noise_private.key";

          prefixes = {
            v4 = "100.101.0.0/16";
            v6 = "fd7a:115c:a1e0:8249::/64";
            allocation = "sequential";
          };

          dns = {
            magic_dns = true;
            base_domain = "fort.${fort.settings.domain}";
            override_local_dns = true;
            extra_records_path = "/var/lib/headscale/extra-records.json";
            nameservers.global = [
              "1.1.1.1"
              "1.0.0.1"
            ];
            search_domains = [ ];
          };

          database = {
            type = "sqlite";
            sqlite = {
              path = "/var/lib/headscale/db.sqlite";
              write_ahead_log = true;
            };
          };

          log = {
            level = "info";
            format = "text";
          };
          derp.server.enabled = false;
        };
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
      services.nginx.enable = true;

      services.nginx.virtualHosts."mesh.${fort.settings.domain}" = {
        forceSSL = true;
        enableACME = true;
        http2 = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:9080";
          proxyWebsockets = true;
          # NixOS nginx includes recommended proxy headers by default
        };
        locations."/headscale.v1.HeadscaleService/" = {
          extraConfig = ''
            grpc_pass grpc://127.0.0.1:50443;
            grpc_set_header Host $host;
            grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };
      };

      security.acme = {
        acceptTerms = true;
        defaults.email = "admin@${fort.settings.domain}";
      };
    }
  ];
}
