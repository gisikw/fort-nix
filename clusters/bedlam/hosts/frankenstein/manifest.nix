rec {
  hostName = "frankenstein";
  device = "e3cf262e-c319-5d58-bfc5-16b531e3377b";

  roles = [ ];

  apps = [ "qwen-tts" ];

  aspects = [ "observable" "nvidia-gpu" ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
