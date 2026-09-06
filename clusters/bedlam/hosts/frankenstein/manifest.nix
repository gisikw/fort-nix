rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    {
      name = "llama-server";
      gpuDevice = 0;
      # HF reports 17,559,178,144 B (16.353 GiB) for the Q4_K_XL and
      # 927,607,488 B (0.864 GiB) for mmproj.  The dense qwen35 GGUF has
      # 65 layers, 4 KV heads, and 256-dimension K and V heads.  q8_0's
      # 34/32-byte block ratio therefore costs 141,440 B/token, or 3.237 GiB
      # at 24,576 tokens.  That leaves 3.546 GiB on a 24 GiB card: reserve
      # 2 GiB for CUDA/compute buffers and retain >=1.5 GiB free.  32K would
      # leave only 2.466 GiB before compute buffers.  q8_0 (set by the app)
      # meaningfully raises the conservative context from 16K with f16 KV.
      contextSize = 24576;
      mmproj = {
        repo = "unsloth/Qwen3.8-27B-GGUF";
        file = "mmproj-F16.gguf";
        sha256 = "cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e";
      };
    }
    {
      name = "ollama";
      accelerator = "cuda";
      gpuDevice = 1;
      modelNames = [ "gemma4-heretic" ];
    }
    # Wyvern voice campaign (c-713b2161) — temporary; remove after voice elicitation.
    # qwen-tts and GPU-0 llama-server cannot coexist. Ollama now shares this
    # box too, but is isolated on GPU 1; stop the conflicting unit explicitly.
    "qwen-tts"
  ];

  # agent-debug: temporary for wyvern campaign (c-713b2161) unkork runs — remove with qwen-tts
  aspects = [
    "observable"
    "nvidia-gpu"
    "gitops"
    "agent-debug"
  ];

  overlays = {
    unkork = {
      package = "infra/unkork";
    };
  };

  module =
    { config, ... }:
    {
      config.fort.host = {
        inherit
          roles
          apps
          aspects
          overlays
          ;
      };
      config.virtualisation.podman.enable = true;
    };
}
