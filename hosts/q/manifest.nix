rec {
  hostName = "q";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [ ];

  aspects = [
    "mesh"
    "observable"
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
