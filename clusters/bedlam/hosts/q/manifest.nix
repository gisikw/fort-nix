rec {
  hostName = "q";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [
    "actualbudget"
    "claude-code-ui"
    "prowlarr"
    "radarr"
    "lidarr"
    "sonarr"
    "readarr"
    "qbittorrent"
    "vikunja"
    "outline"
    "super-productivity"
  ];

  aspects = [
    "mesh"
    "observable"
    "egress-vpn"
  ];

  module =
    { config, pkgs, ... }:
    let
      claude-code = import ../../../../pkgs/claude-code { inherit pkgs; };
    in
    {
      config.fort.host = { inherit roles apps aspects; };
      config.environment.systemPackages = [ claude-code ];
      config.fileSystems."/ingest" = {
        device = "/dev/disk/by-label/ingest";
        fsType = "ext4";
        options = [ "nofail" "x-systemd.device-timeout=5s" ];
      };
    };
}
