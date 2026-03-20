rec {
  hostName = "frankenstein";
  device = "533a26f4-6daf-4eb9-8548-3fb0adb3e4d6";

  roles = [ ];

  apps = [ "vllm" ];

  aspects = [ "observable" "nvidia-gpu" ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
