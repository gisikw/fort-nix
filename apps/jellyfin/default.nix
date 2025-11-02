{ ... }:
{ ... }:
{
  services.jellyfin.enable = true;
  users.users.jellyfin.extraGroups = [ "media" ];

  fortCluster.exposedServices = [
    {
      name = "jellyfin";
      port = 8096;
      visibility = "local";
    }
  ];
}
