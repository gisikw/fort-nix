{ config, pkgs, lib, fort, ... }:

{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  users.users.jellyfin.extraGroups = [ "media" ];

  fort.routes.jellyfin = {
    subdomain = "jellyfin";
    port = 8096;
  };
}
