{ subdomain ? null, ... }:
{ ... }:
{
  services.radarr.enable = true;
  systemd.services.radarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.radarr.wants = [ "egress-vpn-namespace.service" ];
  systemd.services.radarr.after = [ "egress-vpn-namespace.service" ];

  fortCluster.exposedServices = [
    {
      name = "radarr";
      subdomain = subdomain;
      port = 7878;
      inEgressNamespace = true;
    }
  ];
}
