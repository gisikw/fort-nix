{ config, pkgs, lib, fort, ... }:

let
  corednsConfigFile = "/etc/coredns/Corefile";
  fortHostsPath = "/etc/coredns/hosts.conf";
  blockListPath = "/etc/coredns/blocklist.conf";
  combinedHostsPath = "/etc/coredns/combined.conf";
in
{
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
  systemd.services.NetworkManager-wait-online.enable = true;

  systemd.services.fort-coredns-records = {
    description = "Update coredns fallthrough records";
    serviceConfig.Type = "oneshot";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.iproute2 pkgs.curl pkgs.gawk pkgs.coreutils ];

    script = ''
      set -e
      self=$(ip -4 route get 1.1.1.1 | awk '{print $7}')
      tmp=$(mktemp)
      cat ${fortHostsPath} | sed '/ns.${fort.settings.domain}$/d' > $tmp
      {
        echo "$self ns.${fort.settings.domain}"
        cat $tmp
      } > ${fortHostsPath}
      curl -s https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts > ${blockListPath}
      cat ${fortHostsPath} ${blockListPath} > ${combinedHostsPath}
    '';
  };

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

  environment.etc."coredns/Corefile".text = ''
    .:53 {
      hosts ${combinedHostsPath} {
        fallthrough
      } 
      forward . tls://1.1.1.1
      log
    }
  '';

  # Automatically re-merge file entries on change
  systemd.services.merge-coredns-hosts = {
    description = "Merge fort and blocklist hosts for CoreDNS";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "merge-coredns-hosts" ''
        cat ${fortHostsPath} ${blockListPath} > ${combinedHostsPath}
      '';
    };
  };

  systemd.paths."merge-coredns-hosts" = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = [
        fortHostsPath
        blockListPath
      ];
      Unit = "merge-coredns-hosts.service";
    };
  };
}
