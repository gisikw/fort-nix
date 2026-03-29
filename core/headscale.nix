{ config, lib, pkgs, ... }:

let
  domain = config.networking.domain;

  # DERP map — points to self-hosted DERP on the VPS relay
  derpMap = pkgs.writeText "derp.yaml" ''
    regions:
      900:
        regionid: 900
        regioncode: "home"
        regionname: "Home Relay"
        nodes:
          - name: relay
            regionid: 900
            hostname: relay.${domain}
            stunport: 3478
            derpport: 443
  '';
in
{
  services.headscale = {
    enable = true;
    settings = {
      server_url = "https://mesh.${domain}";
      listen_addr = "0.0.0.0:8443";
      metrics_listen_addr = "127.0.0.1:9090";

      db_type = "sqlite3";
      db_path = "/var/lib/headscale/db.sqlite";

      private_key_path = "/var/lib/headscale/private.key";
      noise.private_key_path = "/var/lib/headscale/noise_private.key";

      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };

      # Self-hosted DERP only — no Tailscale infrastructure
      derp = {
        server.enabled = false;    # DERP runs on VPS, not here
        urls = [];                 # Don't fetch Tailscale's DERP map
        paths = [ "${derpMap}" ];  # Our relay only
        auto_update_enabled = false;
      };

      dns = {
        base_domain = domain;
        magic_dns = true;
        nameservers.global = [ "192.168.1.1" ];
      };

      log = {
        level = "info";
      };
    };
  };
}
