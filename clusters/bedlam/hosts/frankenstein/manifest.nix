rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    "ollama-cuda"
    # "qwen-tts"    # Keeping for now — mood sample generation baseline
    # "kvoicewalk"  # Voice training workbench — done for now
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
