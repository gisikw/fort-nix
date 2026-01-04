{ subdomain ? null, ... }:
{ ... }:
{
  services.readarr.enable = true;
  systemd.services.readarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.readarr.wants = [ "egress-vpn-namespace.service" ];
  systemd.services.readarr.after = [ "egress-vpn-namespace.service" ];

  fortCluster.exposedServices = [
    {
      name = "readarr";
      subdomain = subdomain;
      port = 8787;
      inEgressNamespace = true;
    }
  ];
}
