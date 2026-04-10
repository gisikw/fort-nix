{ ... }:
{ config, pkgs, ... }:
let
  ollama-cuda-latest = pkgs.ollama-cuda.overrideAttrs (old: rec {
    version = "0.20.5";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-/H4DZ/aRB04lKSke9XsK+vb76pcy940scoTunXO4pf4=";
    };
    vendorHash = "sha256-1ndXnef1siLKrC0SyAcZmfN8p9pjcOMvcc/boTwBzGc=";
    subPackages = [ "." ];
  });
in
{
  services.ollama = {
    enable = true;
    acceleration = "cuda";
    package = ollama-cuda-latest;
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
