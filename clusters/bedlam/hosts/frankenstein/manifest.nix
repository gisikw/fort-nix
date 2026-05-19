rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    "ollama-cuda"
    # "llama-server"  # temporarily disabled — CUDA build blocking deploy
  ];

  aspects = [ "observable" "nvidia-gpu" "gitops" ];

  overlays = {
    unkork = {
      package = "infra/unkork";
    };
  };

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects overlays; };
      config.virtualisation.podman.enable = true;
    };
}
