{ ... }:
{ config, pkgs, ... }:
{
  services.ollama = {
    enable = true;
    acceleration = "cuda";
    openFirewall = false;
  };

  systemd.services.ollama = {
    serviceConfig = {
      Environment = [
        "OLLAMA_HOST=0.0.0.0:11434"
        "OLLAMA_CONTEXT_LENGTH=32768"
        "OLLAMA_FLASH_ATTENTION=1"
        "OLLAMA_KV_CACHE_TYPE=q8_0"
        "OLLAMA_KEEP_ALIVE=-1"
      ];
    };
  };

  fort.cluster.services = [{
    name = "inference";
    port = 11434;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
  }];
}
