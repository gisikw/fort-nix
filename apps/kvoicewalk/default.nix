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
    };

    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      (builtins.concatStringsSep " && " [
        # System deps
        "apt-get update -qq"
        "apt-get install -qq -y python3 python3-pip python3-venv git ffmpeg sox libsndfile1 >/dev/null 2>&1"
        # Persistent venv
        "test -d /venv/bin || python3 -m venv /venv"
        # Install deps (uv sync won't work outside the repo, so pip install manually)
        "/venv/bin/pip install --cache-dir /pip-cache torch torchaudio --index-url https://download.pytorch.org/whl/cu128 2>&1 | tail -1"
        "/venv/bin/pip install --cache-dir /pip-cache kokoro resemblyzer faster-whisper soundfile numpy scipy 2>&1 | tail -1"
        # Clone or update kvoicewalk
        "test -d /work/kvoicewalk/.git && (cd /work/kvoicewalk && git pull -q) || git clone -q https://github.com/BovineOverlord/kvoicewalk-with-GPU-CUDA-and-GUI-queue-system.git /work/kvoicewalk"
        # Install kvoicewalk's own deps if pyproject.toml exists
        "test -f /work/kvoicewalk/pyproject.toml && /venv/bin/pip install --cache-dir /pip-cache -e /work/kvoicewalk 2>&1 | tail -1 || true"
        # Ready — keep container alive for exec
        "echo 'kvoicewalk workbench ready — docker exec in to use'"
        "exec sleep infinity"
      ])
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--shm-size=4g"
    ];

    volumes = [
      "/var/lib/kvoicewalk/venv:/venv:Z"
      "/var/lib/kvoicewalk/pip-cache:/pip-cache:Z"
      "/var/lib/kvoicewalk/work:/work:Z"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kvoicewalk 0755 root root -"
    "d /var/lib/kvoicewalk/venv 0755 root root -"
    "d /var/lib/kvoicewalk/pip-cache 0755 root root -"
    "d /var/lib/kvoicewalk/work 0755 root root -"
  ];

  systemd.services.podman-kvoicewalk.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };
}
