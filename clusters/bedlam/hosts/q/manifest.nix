rec {
  hostName = "q";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [
    "qbittorrent"
    "vikunja"
  ];

  aspects = [
    "mesh"
    "observable"
    "egress-vpn"
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
