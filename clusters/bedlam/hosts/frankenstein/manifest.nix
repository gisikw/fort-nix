rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    {
      name = "llama-server";
      mmproj = {
        repo = "unsloth/Qwen3.8-27B-GGUF";
        file = "mmproj-F16.gguf";
        sha256 = "cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e";
      };
    }
    # Wyvern voice campaign (c-713b2161) — temporary; remove after voice elicitation.
    # Stop llama-server before generating (both won't fit in 24GB VRAM).
    "qwen-tts"
  ];

  # agent-debug: temporary for wyvern campaign (c-713b2161) unkork runs — remove with qwen-tts
  aspects = [ "observable" "nvidia-gpu" "gitops" "agent-debug" ];

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
