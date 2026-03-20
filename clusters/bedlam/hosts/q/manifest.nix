rec {
  hostName = "q";
  device = "cbc32a2f-a1bc-5a97-a6d8-911ed8c61ba3";

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
