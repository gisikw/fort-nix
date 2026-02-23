rec {
  hostName = "lordhenry";
  device = "17f17980-5d30-11f0-9a98-fe3a96b43f00";

  roles = [ ];

  apps = [
    "comfyui"
    "ollama"
    "open-webui"
    "sillytavern"
    "tts"
    "whisper"
  ];

  aspects = [
    "mesh"
    "observable"
    "gitops"
  ];

  module =
    { config, pkgs, ... }:
    {
      # Disable Compute Wave Store and Resume — MES firmware bug on gfx1151
      # causes GPU hangs under ROCm workloads (ROCm #5590)
      config.boot.kernelParams = [ "amdgpu.cwsr_enable=0" ];

      config.environment.systemPackages = [
        pkgs.ffmpeg
        pkgs.neovim
        pkgs.tailscale
        pkgs.tmux
        pkgs.rsync
      ];

      config.fort.host = { inherit roles apps aspects; };
    };
}
