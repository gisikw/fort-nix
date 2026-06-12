rec {
  hostName = "pettigrew";
  device = "066fda13-2103-5092-ae08-8eade1c6a069";

  roles = [ ];

  apps = [ "backup-offsite" ];

  aspects = [
    "observable"
    { name = "wifi-access"; credentialsFile = ./wifi-credentials.env.sops; }
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
