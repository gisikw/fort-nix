{ subdomain ? null, ... }:
{ config, ... }:
{
  services.audiobookshelf = {
    enable = true;
    host = "127.0.0.1";
    port = 13378;
  };

  users.groups.media = { };
  users.users.audiobookshelf.extraGroups = [ "media" ];

  fortCluster.exposedServices = [
    {
      name = "audiobookshelf";
      subdomain = subdomain;
      port = 13378;
    }
  ];
}
