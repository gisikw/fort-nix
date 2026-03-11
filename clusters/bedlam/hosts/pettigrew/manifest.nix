rec {
  hostName = "pettigrew";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [ "treeline" ];

  aspects = [
    "observable"
    { name = "wifi-access"; credentialsFile = ./wifi-credentials.env.age; }
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
