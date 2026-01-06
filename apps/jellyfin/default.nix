{ subdomain ? null, ... }:
{ ... }:
{
  services.jellyfin.enable = true;
  users.users.jellyfin.extraGroups = [ "media" ];

  fort.cluster.services = [
    {
      name = "jellyfin";
      subdomain = subdomain;
      port = 8096;
      visibility = "local";
    }
  ];
}
