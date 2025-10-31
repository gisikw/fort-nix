{ ... }:
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
      port = 13378;
    }
  ];
}
