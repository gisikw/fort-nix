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

  # PyTorch 2.6 with CUDA 12.6 — SM 12.0 (Blackwell) works through driver
  # forward compatibility with the host's beta NVIDIA driver.
  baseImage = "pytorch/pytorch:2.6.0-cuda12.6-cudnn9-runtime";
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
      ''pip install --cache-dir /pip-cache qwen-tts fastapi uvicorn soundfile >/dev/null 2>&1 && exec python /app/server.py''
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
      visibility = "vpn";
      sso.mode = "none";
      health.endpoint = "/health";
    }
  ];
}
