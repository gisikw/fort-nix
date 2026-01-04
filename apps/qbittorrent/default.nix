{ subdomain ? null, ... }@args:
{ pkgs, ... }:
{
  users.groups.qbittorrent = {};
  users.users.qbittorrent = {
    isSystemUser = true;
    home = "/var/lib/qbittorrent";
    createHome = true;
    group = "qbittorrent";
  };

  systemd.services.qbittorrent = {
    after = [ "egress-vpn-namespace.service" ];
    wants = [ "egress-vpn-namespace.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      NetworkNamespacePath = "/run/netns/egress-vpn";
      ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox";

      Restart = "on-failure";
      RestartSec = 10;
      WorkingDirectory = "/var/lib/qbittorrent";
      User = "qbittorrent";
      Group = "qbittorrent";
    };
  };

  fortCluster.exposedServices = [
    {
      name = "qbittorrent";
      subdomain = subdomain;
      port = 8080;
      inEgressNamespace = true;
    }
  ];
}
