{ rootManifest, ... }:
{ pkgs, ... }:
let
  corednsConfigFile = "/etc/coredns/Corefile";
  fortHostsPath = "/var/lib/coredns/custom.conf";
  mergedHostsPath = "/var/lib/coredns/merged.conf";
  blocklist = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/StevenBlack/hosts/refs/tags/3.16.27/hosts";
    sha256 = "sha256-dmqKd8m1JFzTDXjeZUYnbvZNX/xqMiXYFRJFveq7Nlc=";
  };
  domain = rootManifest.fortConfig.settings.domain;

  # Import fort CLI for querying lan-ip capability
  fortCli = import ../../pkgs/fort { inherit pkgs domain; };

  # Async handler for LAN DNS record configuration
  # Receives aggregate requests, generates hosts file for CoreDNS
  # Input: {"origin:dns-coredns/servicename": {"request": {"fqdn": "..."}}, ...}
  # Output: {"origin:dns-coredns/servicename": "OK", ...}
  dnsCorednsHandler = pkgs.writeShellScript "handler-dns-coredns" ''
    set -euo pipefail

    input=$(${pkgs.coreutils}/bin/cat)
    HOSTS_FILE="${fortHostsPath}"

    # Build response object and hosts content
    response="{}"
    hosts="# Managed by fort dns-coredns capability"

    # Cache LAN IP lookups per origin (avoid repeated calls)
    declare -A lan_ip_cache

    # Process each request
    for key in $(echo "$input" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
      origin=$(echo "$key" | ${pkgs.coreutils}/bin/cut -d: -f1)
      fqdn=$(echo "$input" | ${pkgs.jq}/bin/jq -r --arg k "$key" '.[$k].request.fqdn')

      # Check cache first
      if [ -z "''${lan_ip_cache[$origin]:-}" ]; then
        # Query origin's lan-ip capability
        if result=$(${fortCli}/bin/fort "$origin" lan-ip '{}' 2>/dev/null); then
          lan_ip=$(echo "$result" | ${pkgs.jq}/bin/jq -r '.body.lan_ip // empty')
          if [ -n "$lan_ip" ]; then
            lan_ip_cache[$origin]="$lan_ip"
          else
            lan_ip_cache[$origin]="NOROUTE"
          fi
        else
          lan_ip_cache[$origin]="NOROUTE"
        fi
      fi

      lan_ip="''${lan_ip_cache[$origin]}"

      if [ "$lan_ip" = "NOROUTE" ]; then
        echo "Warning: Could not get LAN IP for origin $origin" >&2
        response=$(echo "$response" | ${pkgs.jq}/bin/jq --arg k "$key" '. + {($k): "ERROR: no LAN IP"}')
        continue
      fi

      # Add hosts entry
      hosts+=$'\n'"$lan_ip $fqdn"

      response=$(echo "$response" | ${pkgs.jq}/bin/jq --arg k "$key" '. + {($k): "OK"}')
    done

    # Write hosts file (path watcher will trigger merge and coredns reload)
    echo "$hosts" > "$HOSTS_FILE"

    echo "$response"
  '';
in
{
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
  systemd.services.NetworkManager-wait-online.enable = true;

  environment.etc."coredns/Corefile".text = ''
    .:53 {
      hosts ${mergedHostsPath} {
        fallthrough
      } 
      forward . tls://1.1.1.1
      log
    }
  '';

  systemd.services.coredns = {
    description = "CoreDNS with dynamic hosts support";
    requires = [ "fort-coredns-records.service" ];
    after = [ "fort-coredns-records.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      ExecStart = "${pkgs.coredns}/bin/coredns -conf ${corednsConfigFile}";
      Restart = "on-failure";
      DynamicUser = true;
      StateDirectory = "coredns";
    };
  };

  systemd.services.fort-coredns-records = {
    description = "Generate merged hosts for CoreDNS";
    wantedBy = [ "coredns.service" ];
    before = [ "coredns.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "fort-coredns-records" ''
        install -Dm0644 ${blocklist} ${mergedHostsPath}
        touch ${fortHostsPath}
        cat ${fortHostsPath} ${blocklist} > ${mergedHostsPath}
      '';
    };
  };

  # Automatically re-merge file entries on change
  systemd.services.merge-coredns-hosts = {
    description = "Merge fort and blocklist hosts for CoreDNS";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "merge-coredns-hosts" ''
        cat ${fortHostsPath} ${blocklist} > ${mergedHostsPath}
      '';
    };
  };

  systemd.paths."merge-coredns-hosts" = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = [ fortHostsPath ];
      Unit = "merge-coredns-hosts.service";
    };
  };

  # Expose dns-coredns capability for LAN DNS record management
  fort.host.capabilities.dns-coredns = {
    handler = dnsCorednsHandler;
    mode = "async";
    triggers.initialize = true;  # Rebuild records on boot
    description = "Configure CoreDNS hosts file for LAN DNS resolution";
  };
}
