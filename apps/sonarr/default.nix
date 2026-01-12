{ subdomain ? null, ... }:
{ ... }:
{
  services.sonarr.enable = true;
  systemd.services.sonarr.serviceConfig.NetworkNamespacePath = "/run/netns/egress-vpn";
  systemd.services.sonarr.wants = [ "egress-vpn-namespace.service" ];
  systemd.services.sonarr.after = [ "egress-vpn-namespace.service" ];

  fort.cluster.services = [
    {
      name = "sonarr";
      subdomain = subdomain;
      port = 8989;
      inEgressNamespace = true;
    }
  ];
}
