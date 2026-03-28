rec {
  hostName = "doofenshmirtz";
  device = "32d93323-a88f-d543-a0b7-08b4d2e63f07";

  roles = [ ];

  apps = [ ];

  aspects = [ "mesh" "observable" { name = "gitops"; manualDeploy = true; } "media-kiosk" ];

  overlays = {
    barely-game-console = {
      package = "dev/barely-game-console";
    };
  };

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
