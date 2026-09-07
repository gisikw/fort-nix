rec {
  hostName = "frankenstein";
  device = "d5ef8d8f-996a-5faf-a477-f1b481eee439";

  roles = [ ];

  apps = [
    # GPU 0: Qwen3.8-27B under vLLM, from syv-ai/qwen38-27b-rtx3090's prebuilt
    # container. Replaces the llama.cpp llama-server that used to own this card:
    # same host port (8012) and same fort service name ("llama"), so the router
    # provider on lordhenry and the golem providers on azula/obrien are unchanged.
    # Where llama.cpp fit 24K of q8_0 KV on a 24 GiB card, this stack's W4A16
    # body plus requantized heads and int8 KV holds ~136k tokens of pool at
    # 131072 max-model-len, with DFlash2 speculation at ~130 tok/s single-stream.
    {
      name = "qwen-vllm";
      gpuDevice = 0;
      # README, "If you are the only user, do this": SPEC=dflash2 + PREFIX_CACHE
      # are worth more than every other knob. CTX=long buys the long context
      # this box is used for (int8 KV, 131072 max-model-len on the dflash2 path).
      # DFLASH_TOKENS stays at the default 7 — 15 is the document-quoting
      # profile and halves the request slots.
      ctx = "long";
      spec = "dflash2";
      # Text only: the router never sends images, and dropping the vision tower
      # gives its weights back to the KV pool.
      vision = false;
    }
    {
      name = "ollama";
      accelerator = "cuda";
      gpuDevice = 1;
      modelNames = [ "gemma4-heretic" ];
    }
    # Speech workloads moved from lordhenry. Parakeet keeps the public `stt`
    # service name and /transcribe API. GPU 0 is unavailable because qwen-vllm
    # fills it, so the ~0.6B model is explicitly confined to GPU 1 alongside
    # Ollama. Expect transient latency/VRAM pressure if both infer concurrently;
    # do not broaden either workload to all GPUs.
    {
      name = "stt";
      gpuDevice = 1;
    }
    # Kokoro is CPU-only. During cutover it is briefly dual-homed with
    # lordhenry; remove the old app only after this instance is verified.
    "tts"
    # Wyvern voice campaign (c-713b2161) — temporary; remove after voice elicitation.
    # qwen-tts still asks for `nvidia.com/gpu=all` and loads its model into
    # whichever card has room, so it cannot coexist with qwen-vllm, which fills
    # GPU 0. Ollama and Parakeet STT share GPU 1. Stop podman-qwen-vllm before
    # generating voice, and start it again after; the coordinator must schedule
    # this because service restarts are intentionally outside this change.
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
