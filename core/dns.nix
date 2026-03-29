{ config, lib, pkgs, ... }:

let
  domain = config.networking.domain;
in
{
  # CoreDNS on port 5353 — dnsmasq on port 53 forwards here
  # This avoids port conflicts and lets dnsmasq handle DHCP + DNS together
  services.coredns = {
    enable = true;
    config = ''
      (common) {
        log
        errors
        cache 300
      }

      # Cluster zone — authoritative for *.weyr.dev
      ${domain}:5353 {
        import common

        # Static host records managed by the core
        # Updated by enrollment, post-receive hooks, etc.
        hosts /var/lib/core-dns/hosts {
          fallthrough
        }

        # SOA so we're authoritative
        template IN SOA ${domain} {
          match ^${domain}[.]$
          answer "${domain}. 3600 IN SOA core.${domain}. admin.${domain}. 2024010100 3600 900 604800 86400"
        }
      }

      # Everything else — forward to upstream resolvers
      .:5353 {
        import common
        forward . 1.1.1.1 8.8.8.8
      }
    '';
  };

  # Hosts file for the cluster zone
  # Format: standard /etc/hosts — one line per record
  # This file is the single source of truth for cluster DNS
  systemd.tmpfiles.rules = [
    "d /var/lib/core-dns 0750 root root -"
    "f /var/lib/core-dns/hosts 0644 root root - 192.168.1.1 core.${domain}"
  ];
}
