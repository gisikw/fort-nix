rec {
  hostName = "ursula";
  device = "8e9779b1-a912-744c-930a-08b4d2e87425";

  roles = [ ];

  apps = [
    "jellyfin"
    "audiobookshelf"
    "calibre-web"
  ];

  aspects = [
    "mesh"
    "observable"
    "gitops"
    {
      name = "zfs";
      extraPools = [ "media" ];
    }
  ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
