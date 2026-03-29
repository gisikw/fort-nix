{ config, lib, pkgs, ... }:

{
  # IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
    # Harden
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
  };

  # nftables: firewall + NAT
  networking.nftables = {
    enable = true;
    ruleset = ''
      table inet filter {
        chain input {
          type filter hook input priority 0; policy drop;

          ct state { established, related } accept
          ct state invalid drop

          iif "lo" accept

          # LAN: allow everything
          iifname "lan0" accept

          # WAN: ICMP echo, DHCP client
          iifname "wan0" icmp type echo-request accept
          iifname "wan0" udp dport 68 accept

          # WAN: headscale (TCP-proxied from VPS on port 8443)
          # Not exposed directly to WAN — VPS handles this

          log prefix "[input-drop] " drop
        }

        chain forward {
          type filter hook forward priority 0; policy drop;

          ct state { established, related } accept
          ct state invalid drop

          # LAN → WAN
          iifname "lan0" oifname "wan0" accept

          # LAN → LAN (inter-host)
          iifname "lan0" oifname "lan0" accept

          log prefix "[forward-drop] " drop
        }

        chain output {
          type filter hook output priority 0; policy accept;
        }
      }

      table ip nat {
        chain postrouting {
          type nat hook postrouting priority 100;
          oifname "wan0" masquerade
        }
      }
    '';
  };

  # DHCP server on LAN
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "lan0";
      bind-interfaces = true;

      # DHCP range — .100 to .250, leaving room for static leases below .100
      dhcp-range = [ "192.168.1.100,192.168.1.250,24h" ];

      # Core is the gateway and DNS server
      dhcp-option = [
        "option:router,192.168.1.1"
        "option:dns-server,192.168.1.1"
      ];

      # Forward DNS queries to local CoreDNS (on port 5353)
      no-resolv = true;
      server = [ "127.0.0.1#5353" ];

      # Static leases — add hosts here as they're enrolled
      # dhcp-host = [
      #   "aa:bb:cc:dd:ee:10,joker,192.168.1.10"
      #   "aa:bb:cc:dd:ee:11,drhorrible,192.168.1.11"
      # ];
    };
  };
}
