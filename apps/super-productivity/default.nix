{ subdomain ? null, rootManifest, ... }:
{ ... }:
let
  fort = rootManifest.fortConfig;
in
{
  virtualisation.oci-containers = {
    containers.super-productivity = {
      image = "containers.${fort.settings.domain}/johannesjo/super-productivity:latest";
      ports = [ "4578:80" ];
    };
  };

  fort.cluster.services = [
    {
      name = "super";
      subdomain = subdomain;
      port = 4578;
    }
  ];
}
