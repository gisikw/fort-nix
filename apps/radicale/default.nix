{ subdomain ? "calendar", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  age.secrets.radicale-htpasswd = {
    file = ./htpasswd.age;
    owner = "radicale";
    group = "radicale";
  };

  services.radicale = {
    enable = true;
    settings = {
      server.hosts = [ "127.0.0.1:5232" ];
      auth = {
        type = "htpasswd";
        htpasswd_filename = config.age.secrets.radicale-htpasswd.path;
        htpasswd_encryption = "bcrypt";
      };
      storage.filesystem_folder = "/var/lib/radicale/collections";
    };
  };

  fort.cluster.services = [
    {
      name = "radicale";
      subdomain = subdomain;
      port = 5232;
      visibility = "public";
      sso.mode = "none"; # Radicale handles auth via htpasswd (CalDAV clients need Basic Auth)
    }
  ];
}
