rec {
  hostName = "joker";
  device = "95ee0c95-b96e-ef43-8898-dc90095d6c5e";

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
