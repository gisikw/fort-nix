{ subdomain ? null, ... }:
{ ... }:
{
  services.prowlarr.enable = true;
  systemd.services.prowlarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.prowlarr.wants = [ "egress-vpn-namespace.service" ];
  systemd.services.prowlarr.after = [ "egress-vpn-namespace.service" ];

  services.flaresolverr.enable = true;
  systemd.services.flaresolverr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.flaresolverr.wants = [ "egress-vpn-namespace.service" ];

  fortCluster.exposedServices = [
    {
      name = "prowlarr";
      subdomain = subdomain;
      port = 9696;
      inEgressNamespace = true;
    }
  ];
}
