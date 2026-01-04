{ subdomain ? null, ... }:
{ ... }:
{
  services.lidarr.enable = true;
  systemd.services.lidarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.lidarr.wants = [ "egress-vpn-namespace.service" ];
  systemd.services.lidarr.after = [ "egress-vpn-namespace.service" ];

  fortCluster.exposedServices = [
    {
      name = "lidarr";
      subdomain = subdomain;
      port = 8686;
      inEgressNamespace = true;
    }
  ];
}
