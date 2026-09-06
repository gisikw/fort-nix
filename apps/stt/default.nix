# NVIDIA Parakeet TDT is an automatic-speech-recognition (ASR/STT) model, not
# a speech synthesizer. This app replaces the old Whisper large-v3 backend while
# retaining the existing /transcribe API and `stt` service/DNS identity.
{
  gpuDevice ? 1,
  ...
}:
{
  config,
  pkgs,
  lib,
  ...
}:

let
  port = 8787;
  stateDir = "/var/lib/parakeet-stt";

  # Immutable amd64 manifest for pytorch/pytorch:2.11.0-cuda12.8-cudnn9-runtime.
  # Python dependencies and the model revision are pinned below; only the HF
  # cache and venv are mutable state, making rollback to the Whisper generation
  # independent of any downloaded model data.
  image = "docker.io/pytorch/pytorch@sha256:eee11b3b3872a8c838e35ef48f08b2d5def2080902c7f666831310ca1a0ef2be";
  modelRevision = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b";
  server = pkgs.writeTextFile {
    name = "parakeet-stt-server";
    text = builtins.readFile ./server.py;
    destination = "/server.py";
  };
in
{
  assertions = [
    {
      assertion = config.virtualisation.podman.enable;
      message = "stt needs podman (virtualisation.podman.enable) on the host";
    }
    {
      assertion = config.hardware.nvidia-container-toolkit.enable;
      message = "Parakeet STT needs CDI: add the 'nvidia-gpu' aspect to this host";
    }
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "d ${stateDir}/hf-cache 0700 root root -"
    "d ${stateDir}/pip-cache 0700 root root -"
    "d ${stateDir}/venv 0700 root root -"
  ];

  virtualisation.oci-containers.containers.parakeet-stt = {
    inherit image;
    ports = [ "127.0.0.1:${toString port}:${toString port}" ];
    environment = {
      HF_HOME = "/hf";
      PARAKEET_MODEL = "nvidia/parakeet-tdt-0.6b-v3";
      PARAKEET_REVISION = modelRevision;
      PORT = toString port;
      PYTHONUNBUFFERED = "1";
    };
    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      (builtins.concatStringsSep " && " [
        # The base image supplies CUDA PyTorch. Keep the comparatively small
        # app environment persistent and version-pinned across restarts.
        "apt-get update -qq"
        "apt-get install -qq -y --no-install-recommends ffmpeg >/dev/null"
        "python -m venv --system-site-packages /venv"
        "/venv/bin/pip install --disable-pip-version-check --cache-dir /pip-cache 'transformers==5.6.0' 'flask==3.1.2' 'gunicorn==23.0.0' >/dev/null"
        # One worker serializes GPU inference and loads exactly one model copy.
        "cd /app && exec /venv/bin/gunicorn --workers 1 --threads 1 --timeout 600 --bind 0.0.0.0:${toString port} server:app"
      ])
    ];
    volumes = [
      "${stateDir}/hf-cache:/hf"
      "${stateDir}/pip-cache:/pip-cache"
      "${stateDir}/venv:/venv"
      "${server}/server.py:/app/server.py:ro"
    ];
    extraOptions = [
      # Frankenstein's GPU 0 is filled by qwen-vllm. Restrict this container to
      # GPU 1, where the ~0.6B ASR model shares compute/VRAM with Ollama. CDI
      # exposes that one physical card as cuda:0 inside the container.
      "--device=nvidia.com/gpu=${toString gpuDevice}"
      "--shm-size=2g"
    ];
  };

  systemd.services.podman-parakeet-stt = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "30s";
      # First activation pulls a ~4.3 GB image, installs the pinned userspace,
      # and downloads the ~0.6B model. The endpoint is unavailable until model
      # loading completes; the fort health probe then checks /health.
      TimeoutStartSec = lib.mkForce "1h";
      TimeoutStopSec = lib.mkForce "60s";
    };
  };

  fort.cluster.services = [
    {
      name = "stt";
      inherit port;
      visibility = "public";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
      health.endpoint = "/health";
    }
  ];
}
