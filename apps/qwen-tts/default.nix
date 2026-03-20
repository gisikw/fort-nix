{ rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  port = 8880;
  voiceDesignPort = 8881;

  voiceDesignScript = pkgs.writeTextFile {
    name = "voice-design-server";
    text = builtins.readFile ./voice-design.py;
    destination = "/voice-design.py";
  };

  # Optimized backend config — 0.6B model for speed on 16GB VRAM (5060 Ti).
  # torch.compile on codebook predictor + TF32 + cuDNN benchmark = ~25-35% speedup.
  # SDPA attention (flash_attention_2 needs CUDA devel image to compile).
  configFile = pkgs.writeText "qwen-tts-config.yaml" ''
    default_model: 0.6B-CustomVoice
    models:
      0.6B-CustomVoice:
        hf_id: Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice
        type: customvoice
      1.7B-CustomVoice:
        hf_id: Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
        type: customvoice
      0.6B-Base:
        hf_id: Qwen/Qwen3-TTS-12Hz-0.6B-Base
        type: base
      1.7B-Base:
        hf_id: Qwen/Qwen3-TTS-12Hz-1.7B-Base
        type: base
    optimization:
      attention: sdpa
      compile_mode: max-autotune
      use_compile: true
      use_cuda_graphs: false
      use_fast_codebook: true
      compile_codebook_predictor: true
      streaming:
        decode_window_frames: 80
        emit_every_frames: 6
    server:
      host: "0.0.0.0"
      port: ${toString port}
    voices:
      - name: Vivian
        language: Chinese
      - name: Serena
        language: Chinese
      - name: Ryan
        language: English
      - name: Aiden
        language: English
      - name: Ono_Anna
        language: Japanese
      - name: Sohee
        language: Korean
  '';

  # CUDA 12.8 runtime — includes SM 12.0 (Blackwell) kernel support.
  baseImage = "nvidia/cuda:12.8.1-runtime-ubuntu24.04";
in
{
  virtualisation.oci-containers.containers.qwen-tts = {
    image = baseImage;
    ports = [
      "127.0.0.1:${toString port}:${toString port}"
      "127.0.0.1:${toString voiceDesignPort}:${toString voiceDesignPort}"
    ];

    environment = {
      HF_HOME = "/hf";
      TTS_BACKEND = "optimized";
      TTS_CONFIG = "/app/config.yaml";
      TTS_WARMUP_ON_START = "true";
      ENABLE_VOICE_STUDIO = "true";
    };

    entrypoint = "/bin/bash";
    cmd = [
      "-c"
      (builtins.concatStringsSep " && " [
        # Install system deps
        "apt-get update -qq"
        "apt-get install -qq -y python3 python3-pip python3-venv git ffmpeg sox libsndfile1 >/dev/null 2>&1"
        # Create or update persistent venv
        "python3 -m venv /venv"
        # Install PyTorch with CUDA 12.8 SM 12.0 (Blackwell) support
        "/venv/bin/pip install --cache-dir /pip-cache torch torchaudio --index-url https://download.pytorch.org/whl/cu128 2>&1 | tail -1"
        # Clone or update the optimized server
        "test -d /app/repo/.git && (cd /app/repo && git pull -q) || git clone -q https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi.git /app/repo"
        # Install project with API deps + gradio for voice studio
        "/venv/bin/pip install --cache-dir /pip-cache -e '/app/repo[api]' gradio 2>&1 | tail -1"
        # Start voice design server in background (lazy-loads VoiceDesign model on first use)
        "/venv/bin/python /app/voice-design.py &"
        # Run main TTS server
        "cd /app/repo && exec /venv/bin/python -m api.main"
      ])
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--shm-size=4g"
    ];

    volumes = [
      "/var/lib/qwen-tts/hf-cache:/hf:Z"
      "/var/lib/qwen-tts/pip-cache:/pip-cache:Z"
      "/var/lib/qwen-tts/venv:/venv:Z"
      "/var/lib/qwen-tts/repo:/app/repo:Z"
      "${configFile}:/app/config.yaml:ro"
      "${voiceDesignScript}/voice-design.py:/app/voice-design.py:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qwen-tts 0755 root root -"
    "d /var/lib/qwen-tts/hf-cache 0755 root root -"
    "d /var/lib/qwen-tts/pip-cache 0755 root root -"
    "d /var/lib/qwen-tts/venv 0755 root root -"
    "d /var/lib/qwen-tts/repo 0755 root root -"
  ];

  systemd.services.podman-qwen-tts.serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = "30s";
  };

  services.nginx.virtualHosts."qwen-tts.${domain}".locations = {
    # Voice Design — standalone page calling qwen_tts VoiceDesign model directly.
    # Runs on separate port, lazy-loads model on first request.
    "/voice-design/" = {
      proxyPass = "http://127.0.0.1:${toString voiceDesignPort}/";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Cookie $http_cookie;
        proxy_read_timeout 300s;
      '';
    };
    # Voice Studio (mounted at /voice-studio/) generates file URLs without its
    # subpath prefix — requests hit /gradio_api/file=... instead of
    # /voice-studio/gradio_api/file=... causing 404s. Rewrite to fix.
    "~ ^/gradio_api/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = ''
        rewrite ^/gradio_api/(.*) /voice-studio/gradio_api/$1 break;
        proxy_set_header Cookie $http_cookie;
      '';
    };
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
