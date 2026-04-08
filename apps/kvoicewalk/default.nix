{ ... }:
{ pkgs, lib, ... }:
let
  # Same CUDA base as qwen-tts — includes headers for torch compilation
  baseImage = "nvidia/cuda:12.8.1-devel-ubuntu24.04";
in
{
  virtualisation.oci-containers.containers.kvoicewalk = {
    image = baseImage;

    environment = {
      PYTHONDONTWRITEBYTECODE = "1";
      UV_CACHE_DIR = "/uv-cache";
    };

    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      (builtins.concatStringsSep " && " [
        # System deps + uv via standalone installer
        "apt-get update -qq"
        "apt-get install -qq -y python3 python3-pip python3-venv git ffmpeg sox libsndfile1 curl >/dev/null 2>&1"
        "curl -LsSf https://astral.sh/uv/install.sh | sh"
        "export PATH=\"$HOME/.local/bin:$PATH\""
        # Clone or update kvoicewalk
        "test -d /work/kvoicewalk/.git && (cd /work/kvoicewalk && git pull -q) || git clone -q https://github.com/BovineOverlord/kvoicewalk-with-GPU-CUDA-and-GUI-queue-system.git /work/kvoicewalk"
        # Ready — keep container alive for exec
        "echo 'kvoicewalk workbench ready — cd /work/kvoicewalk && uv sync'"
        "exec sleep infinity"
      ])
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--shm-size=4g"
    ];

    volumes = [
      "/var/lib/kvoicewalk/uv-cache:/uv-cache:Z"
      "/var/lib/kvoicewalk/uv-data:/root/.local/share/uv:Z"
      "/var/lib/kvoicewalk/uv-bin:/root/.local/bin:Z"
      "/var/lib/kvoicewalk/work:/work:Z"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kvoicewalk 0755 root root -"
    "d /var/lib/kvoicewalk/uv-cache 0755 root root -"
    "d /var/lib/kvoicewalk/uv-data 0755 root root -"
    "d /var/lib/kvoicewalk/uv-bin 0755 root root -"
    "d /var/lib/kvoicewalk/work 0755 root root -"
  ];

  systemd.services.podman-kvoicewalk.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };
}
