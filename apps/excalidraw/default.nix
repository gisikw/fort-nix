{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  # excalidraw/excalidraw only publishes :latest (sha tags are from 2021)
  virtualisation.oci-containers.containers.excalidraw = {
    image = "containers.${domain}/excalidraw/excalidraw:latest";
    ports = [ "127.0.0.1:3688:80" ];
  };

  fort.cluster.services = [
    {
      name = "excalidraw";
      port = 3688;
      visibility = "local";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
      };
    }
  ];
}
