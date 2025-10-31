rec {
  hostName = "drhorrible";
  device = "801cc75b-726d-b24a-b46b-7015fb5bf9cd";

  roles = [ "forge" ];

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
