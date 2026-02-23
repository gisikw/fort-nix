{ ... }:
{ config, pkgs, lib, ... }:
let
  # Override ollama-rocm to a more recent version
  ollama-rocm-latest = pkgs.ollama-rocm.overrideAttrs (old: rec {
    version = "0.15.6";
    src = old.src.override {
      tag = "v${version}";
      hash = "sha256-II9ffgkMj2yx7Sek5PuAgRnUIS1Kf1UeK71+DwAgBRE=";
    };
    vendorHash = "sha256-r7bSHOYAB5f3fRz7lKLejx6thPx0dR4UXoXu0XD7kVM=";
  });
in
{
  services.ollama = {
    enable = true;
    acceleration = "rocm";
    package = ollama-rocm-latest;
    environmentVariables = {
      HCC_AMDGPU_TARGET = "gfx1151";
    };
    rocmOverrideGfx = "11.0.2";
    openFirewall = false;
  };

  systemd.services.gpu-reset = {
    description = "PCI reset AMD GPU to clear wedged state";
    before = [ "ollama.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      GPU_DEV="/sys/bus/pci/devices/0000:c5:00.0"
      if [ -d "$GPU_DEV" ]; then
        echo 1 > "$GPU_DEV/remove"
        sleep 2
      fi
      echo 1 > /sys/bus/pci/rescan
    '';
  };

  systemd.services.ollama = {
    after = [ "gpu-reset.service" ];
    requires = [ "gpu-reset.service" ];
    serviceConfig = {
      Environment = [
        "OLLAMA_HOST=0.0.0.0:11434"
        "OLLAMA_CONTEXT_LENGTH=32768"
        "OLLAMA_USE_MMAP=true"
        "OLLAMA_KEEP_ALIVE=-1"
      ];
    };
  };

  fort.cluster.services = [{
    name = "ollama";
    port = 11434;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
  }];
}
