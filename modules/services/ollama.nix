{ config, pkgs, lib, fort, ... }:

{
  services.ollama = {
    enable = true;
    acceleration = "rocm";
    environmentVariables = {
      HCC_AMDGPU_TARGET = "gfx1102"; # Nearest supported match
    };
    rocmOverrideGfx = "11.0.2";
    openFirewall = true;
  };

  systemd.services.ollama.serviceConfig = {
    Environment = [ "OLLAMA_HOST=0.0.0.0:11434" ];
  };

  services.open-webui = {
    enable = true;
    environment = {
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
      OLLAMA_API_BASE_URL = "http://127.0.0.1:11434/api";
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
      HOME = "/var/lib/open-webui";
    };
    openFirewall = true;
  };

  fort.routes.ai = {
    subdomain = "ai";
    port = 8080;
  };
}
