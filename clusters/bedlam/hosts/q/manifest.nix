rec {
  hostName = "q";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [
    "actualbudget"
    "prowlarr"
    "radarr"
    "lidarr"
    "sonarr"
    "readarr"
    "qbittorrent"
    "vikunja"
    "outline"
    "super-productivity"
    "termix"
    "silverbullet"
    "upload-gateway"
  ];

  aspects = [
    "mesh"
    "observable"
    "egress-vpn"
    "gitops"
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
      config.fileSystems."/ingest" = {
        device = "/dev/disk/by-label/ingest";
        fsType = "ext4";
        options = [ "nofail" "x-systemd.device-timeout=5s" ];
      };
    };
}
