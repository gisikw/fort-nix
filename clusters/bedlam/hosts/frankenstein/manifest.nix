rec {
  hostName = "frankenstein";
  device = "03000200-0400-0500-0006-000700080009";

  roles = [ ];

  apps = [ "vllm" ];

  aspects = [ "observable" "nvidia-gpu" ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
