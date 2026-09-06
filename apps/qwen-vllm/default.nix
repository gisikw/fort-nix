# Qwen3.8-27B on one RTX 3090, served by vLLM from the prebuilt container
# published by https://github.com/syv-ai/qwen38-27b-rtx3090.
#
# This replaces the llama.cpp `llama-server` app on frankenstein. It keeps the
# same host port (8012) and the same fort service name, so the router provider
# (`upstream_base = "http://frankenstein:8012"` on lordhenry) and the golem
# providers on azula/obrien keep working unchanged — see `servedModelName`.
#
# Upstream references (read 2026-09-06):
#   README.md          — "Quick start", "If you are the only user", the CTX/SPEC
#                        tables, the 250 W power-limit paragraph.
#   docs/docker.md     — image contents, host prerequisites, "Plain docker (no
#                        compose)": the `.env` knobs become `-e` flags; the
#                        entrypoint runs the idempotent `prepare` first.
#   docker-compose.yml — volume layout (`/app/models`, `/cache`), `HOME=/cache`,
#                        `ipc: host`, healthcheck (`/health`, 900 s start period).
#   single-user/start_qwen.sh — every env var below, and the hardcoded
#                        `--served-model-name qwen3.8-27b` that EXTRA_ARGS
#                        overrides (EXTRA_ARGS is last on the vllm command line).
{ subdomain ? null
, serviceName ? "llama"

  # Host port. 8012 keeps every existing consumer working; the container itself
  # always serves 18020 (start_qwen.sh's PORT default).
, port ? 8012
  # Published on all interfaces, exactly like the llama-server it replaces
  # (lordhenry reaches this over the tailnet as frankenstein:8012, nginx over
  # loopback). The server is unauthenticated unless apiKeyFile is set — see the
  # comment on that parameter.
, listenAddress ? "0.0.0.0"

  # Which physical GPU. CDI (`nvidia.com/gpu=N`) — the nvidia-gpu aspect enables
  # hardware.nvidia-container-toolkit, which generates the CDI specs, and the
  # qwen-tts app already uses `--device=nvidia.com/gpu=all`.
, gpuDevice ? 0

  # Serving knobs, all read by single-user/start_qwen.sh:
  #   ctx = "fast" — FlashAttention + bf16 KV, ~64k context, 4 drafts
  #   ctx = "long" — int8/fp8 KV via FlashInfer; with SPEC=dflash2 that is a
  #                  ~136k-token pool at 131072 max-model-len (README: "CTX=long
  #                  doubles the DFlash2 pool with int8 KV (138k)"); with mtp it
  #                  is the 150k profile.
  #   ctx = "huge" — KVarN 4/2-bit KV, 240k+ (KVarN is preinstalled in the image).
, ctx ? "long"
  # dflash2: the DFlash2 block drafter, 7 tokens proposed in one pass. README's
  # "If you are the only user, do this" — this plus prefixCache is worth more
  # than every other knob.
, spec ? "dflash2"
, prefixCache ? true
  # Stays at 7. README: DFLASH_TOKENS=15 is for document-quoting workloads, is
  # worth ~1% on chat/agentic traffic, and halves the request slots (4 instead
  # of 8) because the 16-token verify block doubles the recurrent-state page.
, dflashTokens ? 7
  # null = leave the launcher's per-profile default (4 for dflash2 + CTX=long).
  # README: seats are admissions, not residency — raising this only queues.
, maxSeqs ? null
  # The mmproj/vision tower costs VRAM and the router only sends text.
, vision ? false

  # vLLM advertises `qwen3.8-27b` in /v1/models by default (hardcoded
  # --served-model-name in single-user/start_qwen.sh). Every consumer in this
  # repo asks for `Qwen3.8-27B-UD-Q4_K_XL` (the llama.cpp GGUF alias), so we
  # override the served name via EXTRA_ARGS and register both: zero changes in
  # azula/obrien/lordhenry, and clients that learned the upstream name still work.
, servedModelName ? "Qwen3.8-27B-UD-Q4_K_XL"
, extraServedModelNames ? [ "qwen3.8-27b" ]
  # Appended verbatim to EXTRA_ARGS (after the served-name flags).
, extraArgs ? ""
  # Extra environment for the container (any start_qwen.sh knob: INT8_ACT,
  # GPU_UTIL, KV_MEM, LOOKUP, DRAFT_SAMPLE, ...).
, extraEnv ? { }

  # Optional path to a root-owned file containing `VLLM_API_KEY=...`. There is
  # no sops secret for this yet, so the default is unauthenticated — identical
  # to the llama-server this replaces (lordhenry's provider has
  # `credential.kind = "none"`), reachable on the tailnet/LAN and behind the
  # fort token wall for the public vhost.
, apiKeyFile ? null

  # Pinned by digest, 2026-09-06. This is `latest` == tag `sha-0e95195` ==
  # upstream main commit 0e95195 ("single-user: set draft_sample_method on the
  # DFlash2 config", 2026-09-04). Upstream rebuilds `latest` on every push and
  # also publishes immutable `sha-<7>` tags; digest-pinning means a rebuild here
  # is the only thing that can change the running stack.
, image ? "ghcr.io/syv-ai/qwen38-27b-rtx3090@sha256:232b7b6bb19ef1c2d19965667f4fb166bfe4ea42b2c42e86ba34ee1dba623dda"

  # README: "every number in this repo is an RTX 3090 at 250 W ... nothing above
  # 250 W is worth the noise", and docs/docker.md: the limit is a host setting,
  # the container cannot set it. The nvidia-gpu aspect has no power hook, so the
  # app owns it. null skips it.
, powerLimitWatts ? 250
, ...
}:
{ config, pkgs, lib, ... }:
let
  containerPort = 18020;
  stateDir = "/var/lib/qwen-vllm";

  servedNames = lib.concatStringsSep " " ([ servedModelName ] ++ extraServedModelNames);
  # EXTRA_ARGS is the last thing on the `vllm serve` command line, so this
  # --served-model-name wins over the launcher's hardcoded `qwen3.8-27b`.
  vllmExtraArgs = lib.concatStringsSep " " (
    lib.optional (servedModelName != null) "--served-model-name ${servedNames}"
    ++ lib.optional (extraArgs != "") extraArgs
  );

  baseEnv = {
    # The launcher's own port; the host mapping below is what consumers see.
    PORT = toString containerPort;
    # compose sets this; without it the caches land in / instead of the volume.
    HOME = "/cache";
    CTX = ctx;
    SPEC = spec;
    PREFIX_CACHE = if prefixCache then "1" else "0";
    DFLASH_TOKENS = toString dflashTokens;
    VISION = if vision then "1" else "0";
  }
  // lib.optionalAttrs (maxSeqs != null) { MAX_SEQS = toString maxSeqs; }
  // lib.optionalAttrs (vllmExtraArgs != "") { EXTRA_ARGS = vllmExtraArgs; }
  // extraEnv;

  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
in
{
  assertions = [
    {
      assertion = builtins.elem ctx [ "fast" "long" "huge" ];
      message = "qwen-vllm ctx must be one of fast | long | huge";
    }
    {
      assertion = builtins.elem spec [ "mtp" "dflash2" "off" ];
      message = "qwen-vllm spec must be one of mtp | dflash2 | off";
    }
    {
      assertion = dflashTokens > 0;
      message = "qwen-vllm dflashTokens must be positive";
    }
    {
      assertion = config.virtualisation.podman.enable;
      message = "qwen-vllm needs podman (virtualisation.podman.enable) on the host";
    }
    {
      assertion = config.hardware.nvidia-container-toolkit.enable;
      message = "qwen-vllm needs CDI for podman: add the 'nvidia-gpu' aspect to this host";
    }
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    # First boot downloads ~19.5 GB and requantizes it in place (lm_head,
    # embeddings, MTP module, draft vocab, DFlash2 drafter) — budget ~20 GB
    # here. The container runs as root, like vLLM's own image, so these files
    # end up root-owned (docs/docker.md).
    "d ${stateDir}/models 0700 root root -"
    # torch.compile / CUDA-graph / FlashInfer-JIT artifacts. Cold: 2-3 minutes
    # of compile on top of the load; warm: ~1 minute (docs/docker.md).
    "d ${stateDir}/cache 0700 root root -"
  ];

  virtualisation.oci-containers.containers.qwen-vllm = {
    inherit image;
    # Default entrypoint arg is `single` (single-user/start_qwen.sh) but be
    # explicit: `batch` is the other mode and one GPU serves one at a time.
    cmd = [ "single" ];
    environment = baseEnv;
    environmentFiles = lib.optional (apiKeyFile != null) apiKeyFile;
    ports = [ "${listenAddress}:${toString port}:${toString containerPort}" ];
    volumes = [
      "${stateDir}/models:/app/models"
      "${stateDir}/cache:/cache"
    ];
    extraOptions = [
      # CDI: one physical card, enumerated as device 0 inside the container.
      # Chosen over CUDA_VISIBLE_DEVICES because the nvidia-gpu aspect already
      # sets up hardware.nvidia-container-toolkit (CDI specs for podman) and
      # qwen-tts on this same host already uses this mechanism. CDI keeps the
      # other card out of the container's device namespace entirely, so nothing
      # inside can walk onto GPU 1 where ollama lives.
      "--device=nvidia.com/gpu=${toString gpuDevice}"
      # compose sets ipc: host — vLLM's workers need a large /dev/shm.
      "--ipc=host"
      # Same probe compose ships, with a start period long enough for the
      # first-boot prepare + compile.
      "--health-cmd=curl -sf http://127.0.0.1:${toString containerPort}/health || exit 1"
      "--health-interval=30s"
      "--health-timeout=10s"
      "--health-retries=3"
      "--health-start-period=60m"
    ];
  };

  systemd.services.podman-qwen-vllm = {
    after = [ "network-online.target" ] ++ lib.optional (powerLimitWatts != null) "qwen-vllm-power-limit.service";
    wants = [ "network-online.target" ] ++ lib.optional (powerLimitWatts != null) "qwen-vllm-power-limit.service";
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = "30s";
      # First boot: ~9.5 GB image pull, then the entrypoint's `prepare` step
      # downloads ~19.5 GB and requantizes it (~20 GB written into
      # ${stateDir}/models), then torch.compile + CUDA graphs. Upstream's
      # compose healthcheck allows 900 s *after* the model exists; the cold path
      # is comfortably longer, so allow two hours before systemd calls it dead.
      # Warm boots load ~16 GB and replay captured graphs: ~1-2 minutes.
      TimeoutStartSec = lib.mkForce "2h";
      TimeoutStopSec = lib.mkForce "60s";
    };
  };

  # README: every published number is an RTX 3090 pinned at 250 W; above that
  # the card hits 90 C in two minutes and throttles back to the same
  # throughput, below it (200 W) costs a third of decode. docs/docker.md: this
  # is a host setting, the container cannot do it. There is no power-limit hook
  # in the nvidia-gpu aspect, so set it here, before the container starts, and
  # again after every boot.
  systemd.services.qwen-vllm-power-limit = lib.mkIf (powerLimitWatts != null) {
    description = "Pin GPU ${toString gpuDevice} to ${toString powerLimitWatts} W for qwen-vllm";
    wantedBy = [ "multi-user.target" ];
    after = [ "nvidia-container-toolkit-cdi-generator.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Non-fatal: a persistence-mode or driver hiccup should not keep the
      # inference server down.
      ExecStart = "-${nvidiaSmi} -i ${toString gpuDevice} -pl ${toString powerLimitWatts}";
    };
  };

  fort.cluster.services = [{
    name = serviceName;
    inherit port subdomain;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
    # vLLM answers /health unauthenticated; / is a 404 on this server, so the
    # default probe path would read red forever.
    health.endpoint = "/health";
  }];
}
