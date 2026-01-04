{ subdomain ? "tasks", rootManifest, ... }:
{ lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  services.vikunja = {
    enable = true;
    frontendScheme = "http";
    frontendHostname = "localhost";    
    port = 3456;
  };

  fortCluster.exposedServices = [
    {
      name = "vikunja";
      subdomain = subdomain;
      port = 3456;
    }
  ];
}
