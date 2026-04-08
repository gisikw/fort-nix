rec {
  hostName = "robotnik";
  device = "c6e75505-6f53-11f0-a531-38a746309e63";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
