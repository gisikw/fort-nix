{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
  domain = fort.settings.domain;

  # Async handler for DNS record configuration
  # Receives aggregate requests, generates extra-records.json for headscale
  # Input: {"origin:dns-headscale/servicename": {"request": {"fqdn": "..."}}, ...}
  # Output: {"origin:dns-headscale/servicename": "OK", ...}
  dnsHeadscaleHandler = pkgs.writeShellScript "handler-dns-headscale" ''
    set -euo pipefail

    input=$(${pkgs.coreutils}/bin/cat)
    RECORDS_FILE="/var/lib/headscale/extra-records.json"

    # Get tailscale status once for IP lookups
    ts_status=$(${pkgs.tailscale}/bin/tailscale status --json)

    # Build response object and records array
    response="{}"
    records="[]"

    # Process each request
    for key in $(echo "$input" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
      origin=$(echo "$key" | ${pkgs.coreutils}/bin/cut -d: -f1)
      fqdn=$(echo "$input" | ${pkgs.jq}/bin/jq -r --arg k "$key" '.[$k].request.fqdn')

      # Look up origin's IPv4 from tailscale status
      # Check both .Peer (other nodes) and .Self (if origin is this host)
      ipv4=$(echo "$ts_status" | ${pkgs.jq}/bin/jq -r --arg h "$origin" '
        (.Peer | to_entries[] | select(.value.HostName == $h) | .value.TailscaleIPs[0])
        // (if .Self.HostName == $h then .Self.TailscaleIPs[0] else null end)
        // null
      ')

      if [ "$ipv4" = "null" ] || [ -z "$ipv4" ]; then
        echo "Warning: Could not find IP for origin $origin" >&2
        response=$(echo "$response" | ${pkgs.jq}/bin/jq --arg k "$key" '. + {($k): "ERROR: host not found in mesh"}')
        continue
      fi

      # Add A record
      records=$(echo "$records" | ${pkgs.jq}/bin/jq --arg name "$fqdn" --arg ip "$ipv4" \
        '. + [{name: $name, type: "A", value: $ip}]')

      response=$(echo "$response" | ${pkgs.jq}/bin/jq --arg k "$key" '. + {($k): "OK"}')
    done

    # Write records file
    echo "$records" > "$RECORDS_FILE"
    ${pkgs.coreutils}/bin/chown headscale:headscale "$RECORDS_FILE"

    echo "$response"
  '';
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

      # Expose dns-headscale capability for VPN DNS record management
      fort.host.capabilities.dns-headscale = {
        handler = dnsHeadscaleHandler;
        mode = "async";
        triggers.initialize = true;  # Rebuild records on boot
        description = "Configure headscale extra DNS records for service FQDNs";
      };
    }
  ];
}
