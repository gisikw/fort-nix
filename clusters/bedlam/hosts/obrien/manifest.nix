rec {
  hostName = "obrien";
  device = "FFD630C8-2D9B-5C34-BF1F-474943BDB2D9";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
