rec {
  hostName = "pettigrew";
  device = "30e33af3-522c-479d-908b-10e057e5667f";

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
