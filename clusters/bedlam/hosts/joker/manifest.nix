rec {
  hostName = "joker";
  device = "95ee0c95-b96e-ef43-8898-dc90095d6c5e";

  roles = [ ];

  apps = [ ];

  aspects = [
    "mesh"
    "observable"
    "gitops"
    "ci-runner"
    "agent-debug"
  ];

  overlays = {
    wings = {
      package = "infra/wings";
    };
  };

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects overlays; };
      config.environment.systemPackages = [
        (import ../../../../pkgs/claude-code { inherit pkgs; })
      ];
    };
}
