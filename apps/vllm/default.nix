{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  vllmPort = 8000;

  vllmImage = "vllm/vllm-openai:v0.18.0";
in
{
  virtualisation.oci-containers.containers.vllm = {
    image = vllmImage;
    ports = [ "127.0.0.1:${toString vllmPort}:${toString vllmPort}" ];

    environment = {
      HF_HOME = "/hf";
    };

    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      ''pip install soundfile librosa >/dev/null 2>&1 && exec vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation-config '{"cudagraph_mode": "PIECEWISE"}' --tensor-parallel-size 1 --max-model-len 8192 --gpu-memory-utilization 0.55 --host 0.0.0.0 --port ${toString vllmPort}''
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--shm-size=4g"
    ];

    volumes = [
      "/var/lib/vllm/hf-cache:/hf:Z"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/vllm 0755 root root -"
    "d /var/lib/vllm/hf-cache 0755 root root -"
  ];

  # OCI containers module sets Restart=always and TimeoutStartSec=0 (infinite).
  # Override to on-failure so transient crashes don't restart forever.
  systemd.services.podman-vllm.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };

  fort.cluster.services = [
    {
      name = "vllm";
      port = vllmPort;
      visibility = "vpn";
      sso.mode = "none";
      health.endpoint = "/health";
    }
  ];

  # Long-lived WebSocket connections for /v1/realtime audio streaming
  services.nginx.virtualHosts."vllm.${domain}".locations."/".extraConfig = lib.mkAfter ''
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  '';
}
