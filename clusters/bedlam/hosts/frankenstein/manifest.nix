rec {
  hostName = "frankenstein";
  device = "e3cf262e-c319-5d58-bfc5-16b531e3377b";

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
    };
}
