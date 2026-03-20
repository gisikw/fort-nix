{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  vllmPort = 8000;

  # cu130-nightly: CUDA 13.0 build with SM 12.0 (Blackwell) support.
  # No stable release includes SM 12.0 yet. Pin to commit hash for reproducibility.
  vllmImage = "vllm/vllm-openai:cu130-nightly-e3126cd107460444d7fd9a1445b8d4f4393a06b2";
in
{
  virtualisation.oci-containers.containers.vllm = {
    image = vllmImage;
    ports = [ "127.0.0.1:${toString vllmPort}:${toString vllmPort}" ];

    environment = {
      VLLM_DISABLE_COMPILE_CACHE = "1";
      HF_HOME = "/hf";
    };

    # Nightly image is missing soundfile dep needed by mistral_common for audio
    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      ''pip install soundfile >/dev/null 2>&1 && exec vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --enforce-eager --tensor-parallel-size 1 --max-model-len 8192 --gpu-memory-utilization 0.90 --host 0.0.0.0 --port ${toString vllmPort}''
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
