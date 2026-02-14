{ deviceProfileManifest, ... }:
let
  platform = deviceProfileManifest.platform or "nixos";
in
{ lib, ... }:
lib.mkIf (platform == "nixos") {
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    openFirewall = true;
  };
}
