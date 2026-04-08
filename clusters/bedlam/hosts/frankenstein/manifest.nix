rec {
  hostName = "frankenstein";
  device = "e3cf262e-c319-5d58-bfc5-16b531e3377b";

  roles = [ ];

  apps = [ "qwen-tts" "kvoicewalk" ];

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
