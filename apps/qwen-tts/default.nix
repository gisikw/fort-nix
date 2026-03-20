{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  port = 8880;

  serverScript = pkgs.writeTextFile {
    name = "qwen-tts-server";
    text = builtins.readFile ./server.py;
    destination = "/server.py";
  };

  # CUDA 12.8 runtime — includes SM 12.0 (Blackwell) kernel support.
  # PyTorch cu126 lacks SM 12.0 kernels and PTX JIT fails for bf16 casts.
  baseImage = "nvidia/cuda:12.8.1-runtime-ubuntu24.04";
in
{
  virtualisation.oci-containers.containers.qwen-tts = {
    image = baseImage;
    ports = [ "127.0.0.1:${toString port}:${toString port}" ];

    environment = {
      HF_HOME = "/hf";
    };

    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      (builtins.concatStringsSep " && " [
        # Install Python + system deps (fast, ~10s)
        "apt-get update -qq"
        "apt-get install -qq -y python3 python3-pip python3-venv ffmpeg sox libsndfile1 >/dev/null 2>&1"
        # Create venv + install PyTorch with CUDA 12.8 SM 12.0 support
        "python3 -m venv /opt/venv"
        "/opt/venv/bin/pip install --cache-dir /pip-cache torch torchaudio --index-url https://download.pytorch.org/whl/cu128 2>&1 | tail -1"
        # Install qwen-tts + API deps
        "/opt/venv/bin/pip install --cache-dir /pip-cache qwen-tts fastapi uvicorn soundfile 2>&1 | tail -1"
        # Run server
        "exec /opt/venv/bin/python /app/server.py"
      ])
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--shm-size=4g"
    ];

    volumes = [
      "/var/lib/qwen-tts/hf-cache:/hf:Z"
      "/var/lib/qwen-tts/pip-cache:/pip-cache:Z"
      "${serverScript}/server.py:/app/server.py:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qwen-tts 0755 root root -"
    "d /var/lib/qwen-tts/hf-cache 0755 root root -"
    "d /var/lib/qwen-tts/pip-cache 0755 root root -"
  ];

  systemd.services.podman-qwen-tts.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };

  fort.cluster.services = [
    {
      name = "qwen-tts";
      port = port;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
        groups = [ "admin" ];
      };
      health.endpoint = "/health";
    }
  ];
}
