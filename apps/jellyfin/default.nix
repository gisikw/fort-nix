{ subdomain ? null, ... }:
{ ... }:
{
  services.jellyfin.enable = true;
  users.users.jellyfin.extraGroups = [ "media" ];

  fortCluster.exposedServices = [
    {
      name = "jellyfin";
      subdomain = subdomain;
      port = 8096;
      visibility = "local";
    }
  ];
}
