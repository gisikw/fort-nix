{ rootManifest, ... }:
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

  fortCluster.exposedServices = [
    {
      name = "super";
      port = 4578;
    }
  ];
}
