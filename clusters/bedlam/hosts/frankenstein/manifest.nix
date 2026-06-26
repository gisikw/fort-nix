rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    {
      name = "llama-server";
      mmproj = {
        repo = "unsloth/Qwen3.6-27B-MTP-GGUF";
        file = "mmproj-F16.gguf";
        sha256 = "eacf610d1ee4bd5ed0197a0777dd8f4fceb8eefa27009067c7d496cb68fbde45";
      };
    }
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
