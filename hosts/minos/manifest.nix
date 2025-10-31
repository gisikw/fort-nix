rec {
  hostName = "minos";
  device = "bc186c00-30ac-11ef-8d7b-488ccae81000";

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
