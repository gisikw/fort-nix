{ config, pkgs, lib, fortDomain, ... }:

let
  corednsConfigFile = "/etc/coredns/Corefile";
  fortHostsPath = "/etc/coredns/hosts.conf";
  blockListPath = "/etc/coredns/blocklist.conf";
in
{
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  systemd.services.coredns = {
    description = "CoreDNS with dynamic hosts support";
    requires = [ "fort-coredns-records.service" ];
    after = [ "network.target" "fort-coredns-records.service" ];
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
      hosts ${fortHostsPath} ${blockListPath} {
        fallthrough
      }
      forward . tls://1.1.1.1
      log
    }
  '';

  systemd.services.fort-coredns-records = {
    description = "Update coredns fallthrough records";
    serviceConfig.Type = "oneshot";

    path = [ pkgs.iproute2 pkgs.curl pkgs.gawk pkgs.coreutils ];

    script = ''
      set -e
      self=$(ip -4 route get 1.1.1.1 | awk '{print $7}')
      tmp=$(mktemp)
      sed '/ns.${fortDomain}$/d' ${fortHostsPath} > $tmp
      {
        echo "$self ns.${fortDomain}"
        cat $tmp
      } > ${fortHostsPath}
      curl -s https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts > ${blockListPath}
    '';
  };
}
