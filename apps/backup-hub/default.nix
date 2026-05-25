{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  port = 8000;
in
{
  services.restic.server = {
    enable = true;
    listenAddress = "127.0.0.1:${toString port}";
    dataDir = "/var/lib/restic-repos";
    appendOnly = true;
    prometheus = true;
    extraFlags = [ "--no-auth" ];
  };

  fort.cluster.services = [
    {
      name = "backup";
      inherit port;
      visibility = "vpn";
      sso.mode = "none";
    }
  ];
}
