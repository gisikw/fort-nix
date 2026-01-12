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
}
