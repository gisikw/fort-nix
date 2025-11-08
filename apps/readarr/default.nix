{ ... }:
{ ... }:
{
  services.readarr.enable = true;
  systemd.services.readarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.readarr.wants = [ "egress-vpn-namespace.service" ];

  fortCluster.exposedServices = [
    {
      name = "readarr";
      port = 8787;
      inEgressNamespace = true;
    }
  ];
}
