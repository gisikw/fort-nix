rec {
  hostName = "lordhenry";
  device = "17f17980-5d30-11f0-9a98-fe3a96b43f00";

  roles = [ ];

  apps = [
    "ollama"
    "sillytavern"
  ];

  aspects = [
    "mesh"
    "observable"
  ];

  module =
    { config, pkgs, ... }:
    {
      config.environment.systemPackages = [
        pkgs.neovim
        pkgs.tailscale
        pkgs.tmux
        pkgs.rsync
      ];

      config.fort.host = { inherit roles apps aspects; };
    };
}
