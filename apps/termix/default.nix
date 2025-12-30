{ rootManifest, ... }:
{ ... }:
let
  fort = rootManifest.fortConfig;
in
{
  virtualisation.oci-containers = {
    containers.termix = {
      image = "containers.${fort.settings.domain}/ghcr.io/lukegus/termix:latest";
      ports = [ "8080:8080" ];
      volumes = [
        "/var/lib/termix:/app/data"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/termix 0755 root root -"
  ];

  fortCluster.exposedServices = [
    {
      name = "termix";
      port = 8080;
    }
  ];
}
