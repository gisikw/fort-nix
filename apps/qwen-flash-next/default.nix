# Exact experimental stack evidenced on lordhenry:
# Qwen3.8-Flash-Next 177B IQ4_NL-PROJFIX, pwilkin llama.cpp/HIP, ROCm0.
# READ README.md before deployment or rollback.
{
  subdomain ? null,
  serviceName ? "qwen-next",
  port ? 8014,
  provisionModel ? true,
  tuneGtt ? true,
  ...
}:
{
  pkgs,
  lib,
  ...
}:
let
  runtime = import ../../pkgs/pwilkin-rocm-strix { inherit pkgs; };
  llama = import ../../pkgs/llama-cpp-pwilkin-strix { inherit pkgs runtime; };
  rocm = pkgs.rocmPackages;

  repo = "ilintar/qwen3.8-flash-next-gguf-strix-halo";
  modelStore = "/var/lib/qwen-flash-next/models";
  modelAlias = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX";
  contextSize = 262144;
  batchSize = 16384;
  minimumAvailableKiB = 8 * 1024 * 1024;

  # Exact HF LFS lengths and oids. The nine files total 100,043,569,504 bytes.
  shards = [
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf";
      size = 2973690144;
      sha256 = "5b6032b1f3428a148a3b63d661a992dbe0e5f8e278ab684b3d2b474bc5372d30";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00002-of-00009.gguf";
      size = 28800138432;
      sha256 = "81ea612c230e5c3ee1e1036873b316bd6f3d0ba00aa9e12da9238b3ec75ef643";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00003-of-00009.gguf";
      size = 11241902944;
      sha256 = "d4c2432777ad3f2073989d9b584aaa69ea53201c22bfa69b0efc58fb3d4ffb9c";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00004-of-00009.gguf";
      size = 11246708576;
      sha256 = "72e276e9ffd33891b0640136b7f8c3ac765d34b3fae57d91cdbd4d25ce61477c";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00005-of-00009.gguf";
      size = 11213964768;
      sha256 = "c61c34d8c6e27051fb903f7117c6577cbd87b945e7fcdd3b7642a794dec78bac";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00006-of-00009.gguf";
      size = 11231189024;
      sha256 = "c9b36bca38ad5994c24a9d840460c7c3763cd64dfe2816effe1eabef5d7fc77a";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00007-of-00009.gguf";
      size = 11246708576;
      sha256 = "b18c40e93081df6b1001ed344af7de796f07a754f23001376cc9ed2d400effba";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00008-of-00009.gguf";
      size = 11084166688;
      sha256 = "3389e8907ce093d3ad45f5b46f14098d34352241cbc676361edbed7186ab023e";
    }
    {
      file = "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00009-of-00009.gguf";
      size = 1005100352;
      sha256 = "8229be447e559c6f1186d8c878621afcf3466de71aca1b1c97e895288723b36e";
    }
  ];
  firstShard = builtins.head shards;
  totalBytes = lib.foldl' (sum: shard: sum + shard.size) 0 shards;
  artifactsJson = builtins.toJSON shards;
  manifestId = builtins.substring 0 20 (builtins.hashString "sha256" artifactsJson);
  completeMarker = "${modelStore}/.${modelAlias}-${manifestId}.complete";
  marginBytes = 16 * 1024 * 1024 * 1024;

  runtimeLibraryPath = lib.makeLibraryPath [
    "${runtime}/hip"
    "${runtime}/rocr"
    rocm.clr
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocblas
    rocm.llvm.clang
    llama
  ];

  reconcileScript = pkgs.writeShellScript "qwen-flash-next-iq4nl-reconcile" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ]
    }:$PATH
    store=${lib.escapeShellArg modelStore}
    complete=${lib.escapeShellArg completeMarker}
    mkdir -p "$store"

    # A matching marker means this exact manifest was already hash-verified.
    # Retest all lengths without streaming 93 GiB through the page cache on
    # every timer tick. Any missing/truncated file invalidates the marker.
    if [ "$(cat "$complete" 2>/dev/null || true)" = '${manifestId}' ]; then
      valid=1
      count=$(jq length <<'JSON'
    ${artifactsJson}
    JSON
      )
      for i in $(seq 0 $((count - 1))); do
        file=$(jq -r ".[$i].file" <<'JSON'
    ${artifactsJson}
    JSON
        )
        size=$(jq -r ".[$i].size" <<'JSON'
    ${artifactsJson}
    JSON
        )
        [ "$(stat -c %s "$store/$file" 2>/dev/null || echo 0)" = "$size" ] || valid=0
      done
      if [ "$valid" = 1 ]; then
        echo "Artifact reconciliation complete (manifest ${manifestId}; lengths rechecked)."
        exit 0
      fi
      rm -f "$complete"
    else
      # An old manifest marker must never authorize this shard set.
      rm -f "$complete"
    fi

    count=$(jq length <<'JSON'
    ${artifactsJson}
    JSON
    )
    # Remove a same-length but wrong-hash target before capacity arithmetic so
    # its released blocks are counted and the 16 GiB final margin is real.
    for i in $(seq 0 $((count - 1))); do
      file=$(jq -r ".[$i].file" <<'JSON'
    ${artifactsJson}
    JSON
      )
      size=$(jq -r ".[$i].size" <<'JSON'
    ${artifactsJson}
    JSON
      )
      want=$(jq -r ".[$i].sha256" <<'JSON'
    ${artifactsJson}
    JSON
      )
      target="$store/$file"
      if [ "$(stat -c %s "$target" 2>/dev/null || echo 0)" = "$size" ]; then
        actual=$(sha256sum "$target" | cut -d' ' -f1)
        if [ "$actual" != "$want" ]; then
          echo "WARN: removing wrong hash for $file" >&2
          rm -f "$target"
        fi
      fi
    done

    needed=0
    for i in $(seq 0 $((count - 1))); do
      file=$(jq -r ".[$i].file" <<'JSON'
    ${artifactsJson}
    JSON
      )
      size=$(jq -r ".[$i].size" <<'JSON'
    ${artifactsJson}
    JSON
      )
      have=$(stat -c %s "$store/$file" 2>/dev/null || echo 0)
      if [ "$have" != "$size" ]; then
        partial=$(stat -c %s "$store/$file.downloading" 2>/dev/null || echo 0)
        [ "$partial" -le "$size" ] || partial=0
        needed=$((needed + size - partial))
      fi
    done

    if [ "$needed" -gt 0 ]; then
      avail=$(($(stat -f -c '%a * %S' "$store")))
      required=$((needed + ${toString marginBytes}))
      if [ "$avail" -lt "$required" ]; then
        echo "BLOCKED: need $((required / 1024 / 1024 / 1024)) GiB free under $store" \
          "($((needed / 1024 / 1024 / 1024)) GiB remaining + 16 GiB margin)," \
          "have $((avail / 1024 / 1024 / 1024)) GiB; not downloading." >&2
        exit 1
      fi
    fi

    failed=0
    for i in $(seq 0 $((count - 1))); do
      file=$(jq -r ".[$i].file" <<'JSON'
    ${artifactsJson}
    JSON
      )
      size=$(jq -r ".[$i].size" <<'JSON'
    ${artifactsJson}
    JSON
      )
      want=$(jq -r ".[$i].sha256" <<'JSON'
    ${artifactsJson}
    JSON
      )
      target="$store/$file"
      partial="$target.downloading"
      url="https://huggingface.co/${repo}/resolve/main/$file"

      if [ "$(stat -c %s "$target" 2>/dev/null || echo 0)" = "$size" ]; then
        actual=$(sha256sum "$target" | cut -d' ' -f1)
        if [ "$actual" = "$want" ]; then
          echo "OK: $file"
          continue
        fi
        echo "WARN: removing wrong hash for $file" >&2
        rm -f "$target"
      fi
      if [ "$(stat -c %s "$partial" 2>/dev/null || echo 0)" = "$size" ]; then
        actual=$(sha256sum "$partial" | cut -d' ' -f1)
        if [ "$actual" = "$want" ]; then
          mv -f "$partial" "$target"
          echo "DONE: $file (validated staging file)"
          continue
        fi
        rm -f "$partial"
      fi

      echo "Downloading $file"
      if ! curl -C - -L --fail --retry 4 --retry-all-errors --retry-delay 15 \
        --retry-max-time 1800 --connect-timeout 30 --speed-limit 1048576 \
        --speed-time 300 -o "$partial" "$url"; then
        echo "ERROR: bounded download failed for $file; next timer will resume." >&2
        failed=$((failed + 1))
        continue
      fi
      [ "$(stat -c %s "$partial")" = "$size" ] || {
        echo "ERROR: wrong length for $file; deleting staging file." >&2
        rm -f "$partial"
        failed=$((failed + 1))
        continue
      }
      actual=$(sha256sum "$partial" | cut -d' ' -f1)
      if [ "$actual" != "$want" ]; then
        echo "ERROR: hash mismatch for $file (want $want, got $actual); deleting." >&2
        rm -f "$partial"
        failed=$((failed + 1))
        continue
      fi
      mv -f "$partial" "$target"
      echo "DONE: $file"
    done
    [ "$failed" = 0 ] || exit 1

    # The marker is the atomic set-level commit: the server cannot observe a
    # partial shard set even though each very large shard is staged separately.
    marker_tmp="$complete.tmp"
    printf '%s\n' '${manifestId}' > "$marker_tmp"
    mv -f "$marker_tmp" "$complete"
    echo "Artifact reconciliation complete (${toString totalBytes} bytes)."
  '';

  hostPreflight = pkgs.writeShellScript "qwen-flash-next-host-preflight" ''
    set -euo pipefail
    mem_kib=$(${pkgs.gawk}/bin/awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    [ "$mem_kib" -ge 125000000 ] || {
      echo "Qwen IQ4_NL requires the qualified ~128 GiB host; MemTotal=$mem_kib KiB" >&2
      exit 1
    }
    uma=""
    for f in /sys/class/drm/card*/device/mem_info_vram_total; do
      [ -r "$f" ] || continue
      value=$(cat "$f")
      [ "$value" -gt 0 ] || continue
      uma="$value"
      break
    done
    [ "$uma" = 2147483648 ] || {
      echo "BIOS prerequisite not met: expected 2 GiB UMA (2147483648), got ''${uma:-unknown}; Fort does not manage firmware" >&2
      exit 1
    }
    available=$(${pkgs.gawk}/bin/awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
    [ "$available" -ge ${toString minimumAvailableKiB} ] || {
      echo "memory guard: MemAvailable=$available KiB is below 8 GiB; refusing model start" >&2
      exit 1
    }
    [ "$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg completeMarker} 2>/dev/null || true)" = '${manifestId}' ] || {
      echo "model manifest is absent or stale: ${completeMarker}" >&2
      exit 1
    }
  '';

  memoryGuard = pkgs.writeShellScript "qwen-flash-next-memory-guard" ''
    set -uo pipefail
    "$@" & child=$!
    terminate() { kill -TERM "$child" 2>/dev/null || true; wait "$child" || true; }
    trap terminate TERM INT HUP
    low=0
    while kill -0 "$child" 2>/dev/null; do
      sleep 5
      available=$(${pkgs.gawk}/bin/awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
      if [ "$available" -lt ${toString minimumAvailableKiB} ]; then
        low=$((low + 1))
      else
        low=0
      fi
      if [ "$low" -ge 3 ]; then
        echo "memory guard: MemAvailable stayed below 8 GiB for 15s; stopping only llama-server" >&2
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" || true
        exit 70
      fi
    done
    wait "$child"
  '';

  readiness = pkgs.writeShellScript "qwen-flash-next-readiness" ''
    set -euo pipefail
    deadline=$((SECONDS + 2700))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if ${pkgs.curl}/bin/curl -fsS --max-time 2 http://127.0.0.1:${toString port}/health >/dev/null \
        && ${pkgs.curl}/bin/curl -fsS --max-time 2 http://127.0.0.1:${toString port}/v1/models \
          | ${pkgs.jq}/bin/jq -e --arg id ${lib.escapeShellArg modelAlias} '.data | any(.id == $id)' >/dev/null; then
        echo "Qwen API ready: ${modelAlias}"
        exit 0
      fi
      remaining=$((deadline - SECONDS))
      [ "$remaining" -gt 0 ] || break
      [ "$remaining" -lt 2 ] && sleep "$remaining" || sleep 2
    done
    echo "Qwen process did not become API-ready within 45 minutes" >&2
    exit 1
  '';

  serverArgs = [
    "${llama}/bin/llama-server"
    "--host"
    "127.0.0.1"
    "--port"
    (toString port)
    "--model"
    "${modelStore}/${firstShard.file}"
    "--alias"
    modelAlias
    "--jinja"
    "--device"
    "ROCm0"
    "--gpu-layers"
    "999"
    "--flash-attn"
    "on"
    "--cache-type-k"
    "f16"
    "--cache-type-v"
    "f16"
    "--load-mode"
    "none"
    "--lazy-mode"
    "on-direct"
    "--batch-size"
    (toString batchSize)
    "--ubatch-size"
    (toString batchSize)
    "--parallel"
    "1"
    "--ctx-size"
    (toString contextSize)
    "--no-context-shift"
    "--metrics"
  ];

  declarationFixture = pkgs.writeText "qwen-flash-next-declaration.json" (
    builtins.toJSON {
      inherit shards serverArgs;
      environment = requiredEnvironment;
      context = contextSize;
      batch = batchSize;
      total = totalBytes;
      listener = "127.0.0.1:${toString port}";
      engineRevision = llama.sourceRevision;
      engineSourceHash = llama.sourceHash;
      runtimeRevision = runtime.sourceRevision;
      runtimeSourceHash = runtime.sourceHash;
      artifacts = {
        inherit completeMarker manifestId;
      };
    }
  );
  declarationTest =
    pkgs.runCommand "qwen-flash-next-declaration-test" { nativeBuildInputs = [ pkgs.jq ]; }
      ''
        jq -e '
          (.shards | length == 9) and
          ([.shards[].file] | unique | length == 9) and
          ([.shards[].sha256] | unique | length == 9) and
          ([.shards[].size] | add == 100043569504) and
          (.context == 262144) and (.batch == 16384) and
          (.listener == "127.0.0.1:8014") and
          (.engineRevision == "f5daaa3cfa6358e5dd398911ec741813745a5440") and
          (.engineSourceHash == "sha256-9YrpYJ1K2FdDhqstcfdwWMjTl7UhBL0ZHBOP6+KbyoY=") and
          (.runtimeRevision == "7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1") and
          (.runtimeSourceHash == "sha256-URmOwL8itq2lwzfkRD4QtRuoAcBRHva2sLJ+vl0wjbE=") and
          (.artifacts.manifestId == "2f152a082cdff9959d5a") and
          (.artifacts.completeMarker == "/var/lib/qwen-flash-next/models/.Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-2f152a082cdff9959d5a.complete") and
          # GGML_CUDA_ENABLE_UNIFIED_MEMORY must stay ABSENT, not "0": the engine
          # gates on getenv() presence, so any value re-enables the corrupting
          # managed-allocation path. See requiredEnvironment below for evidence.
          ((.environment | has("GGML_CUDA_ENABLE_UNIFIED_MEMORY")) | not) and
          (.environment.GGML_HIP_ENABLE_UNIFIED_MEMORY == "1") and
          (.serverArgs | index("ROCm0") != null) and
          (.serverArgs | index("--gpu-layers") != null) and
          (.serverArgs | index("--flash-attn") != null) and
          (.serverArgs | index("--cache-type-k") != null) and
          (.serverArgs | index("--cache-type-v") != null) and
          (.serverArgs | index("--load-mode") != null) and
          (.serverArgs | index("--lazy-mode") != null) and
          (.serverArgs | index("--no-context-shift") != null) and
          (.serverArgs | index("--spec-draft-model") == null) and
          (.serverArgs | index("--spec-type") == null)
        ' ${declarationFixture} >/dev/null
        jq -r '.shards[].sha256' ${declarationFixture} | sha256sum \
          | grep -q '^31e59ad6da093e045b724c3405580a3c4415f8f9f3ba10ece753b9304825f3b2 '
        mkdir -p "$out"
        cp ${declarationFixture} "$out/fixture.json"
      '';

  requiredEnvironment = {
    HSA_OVERRIDE_GFX_VERSION = "11.5.1";
    GGML_HIP_ENABLE_UNIFIED_MEMORY = "1";
    # GGML_CUDA_ENABLE_UNIFIED_MEMORY is deliberately NOT set.
    #
    # Setting it made this exact stack fast but semantically corrupt: the model
    # emitted a couple of correct tokens and then collapsed into a flood of '/'
    # (token 14) with NaN logits -- /completion returned `logprob: null` and a
    # top-k of the lowest vocabulary ids (0-4), i.e. a degenerate logit vector.
    # Raw /completion, /v1/chat/completions and tool calls all reproduced it, so
    # it was never a chat-template or reasoning-parsing problem.
    #
    # Direct A/B on lordhenry (2026-09-13), same binary/shards/flags, only this
    # variable changed, at both 16384 and the production 262144 context:
    #   present : "The capital of France is Paris.//////////////"
    #             chat -> finish_reason=length, content "////...", no tool_calls
    #   ABSENT  : "The capital of France is Paris. The capital of Germany is
    #             Berlin. The capital of Italy is Rome."
    #             chat -> finish_reason=stop, content "OK"
    #             tools -> finish_reason=tool_calls, get_weather{"city":"Paris"}
    #
    # Absence is load-bearing and distinct from "0": the engine tests only for
    # the variable's presence, so GGML_CUDA_ENABLE_UNIFIED_MEMORY=0 still
    # selects the broken path. Do not "disable" it by setting it to 0.
    #
    # The 2 GiB UMA firmware split is unaffected -- weights land in GTT via the
    # amdgpu.gttsize/ttm kernel params below (gtt_used ~84.5 GB with the full
    # 262144 KV cache resident), so the qualified memory posture is retained and
    # no firmware change is required. A same-boot, same-binary requalification
    # changing only this variable's presence found no throughput penalty:
    # pp16384 was 1070.23 t/s at depth 0 and 1038.07 at depth 40000, while
    # tg128 improved to 32.33 and 19.96 t/s respectively. Correct server output
    # was separately demonstrated at 32.97 t/s. The retained depth-114688 and
    # depth-245760 figures still need correctness-preserving requalification.
    #
    # The HIP-spelled variable above is retained: it was present in both the
    # broken and the proven-good runs and is not the trigger.
    ENABLE_RETAINED_PM4 = "1";
    DEBUG_HIP_GRAPH_PM4 = "1";
    LLAMA_MMB = "1";
    LLAMA_MMB_MIN_T = "512";
    LLAMA_MMB_BF16W = "1";
    LLAMA_MMB_GLU = "1";
    LLAMA_MMB_TALL = "2";
    LLAMA_MMB_CACHE = "4";
    LLAMA_MMB_F32SPLIT = "2";
    LLAMA_MMB_HC16 = "2";
    LLAMA_MMB_SHADOW = "2";
    LLAMA_MMB_DOWN16 = "1";
    LLAMA_HC_CN_SHAPE = "1";
    LLAMA_HC_GATEMIX = "1";
    LLAMA_HC_MIX_FUSE = "1";
    LLAMA_HC_BLK16 = "1";
    LLAMA_HC_RES16 = "1";
    LLAMA_HC_PACK_DI = "1";
    LLAMA_NORM_GATED = "1";
    LLAMA_NORM_ROWS = "1";
    LLAMA_IDX_RELU_SUM = "1";
    LLAMA_PLE_CONV = "1";
    LLAMA_GDN_CONV = "1";
    LLAMA_QSA_SPARSE = "1";
    LLAMA_QSA_WHOLE_ATTN = "1";
    LLAMA_QSA_BLOCK_SELECTION = "1";
    LLAMA_QSA_COMPACT_METADATA = "1";
    LLAMA_QSA_DENSE_SHORTCUT = "1";
    LLAMA_QSA_DIRECT_INDICES = "1";
    LLAMA_QSA_PACK_KEYS = "1";
    LLAMA_QSA_PACK_VALUES = "1";
    LLAMA_QSA_QUERY_STRIP = "512";
    LLAMA_QSA_SCORE_BOUNDS = "1";
    LLAMA_QSA_NO_DENSE_MASK = "1";
    LLAMA_QSA_FA_V3 = "1";
    LLAMA_QSA_FUSE_EXPAND = "1";
    LLAMA_MTP_QSA = "1";
    LLAMA_MTP_QSA_MIN_T = "128";
    LD_LIBRARY_PATH = runtimeLibraryPath;
  };
in
{
  assertions = [
    {
      assertion = builtins.length shards == 9;
      message = "qwen-flash-next: IQ4_NL must have exactly nine shards";
    }
    {
      assertion = totalBytes == 100043569504;
      message = "qwen-flash-next: IQ4_NL byte total changed";
    }
    {
      assertion = builtins.length (lib.unique (map (s: s.file) shards)) == 9;
      message = "qwen-flash-next: duplicate shard filename";
    }
    {
      assertion = contextSize == 262144 && batchSize == 16384;
      message = "qwen-flash-next: qualified context/batch constants changed";
    }
    {
      assertion = port == 8014;
      message = "qwen-flash-next: this replacement candidate intentionally retains private port 8014";
    }
    {
      # Presence alone selects the corrupting managed-allocation path in this
      # engine, so "0" is NOT a disable. Proven by direct A/B on lordhenry:
      # with it set the model emits '/' floods with NaN logits; absent it is
      # coherent and emits tool calls. Keep it absent.
      assertion = !(requiredEnvironment ? GGML_CUDA_ENABLE_UNIFIED_MEMORY);
      message = "qwen-flash-next: GGML_CUDA_ENABLE_UNIFIED_MEMORY must remain unset (any value, including \"0\", reintroduces corrupt semantic output)";
    }
  ];

  # Built by every lordhenry system build; this is evaluation/build-time only
  # and cannot download model data.
  system.extraDependencies = [ declarationTest ];

  hardware.graphics.enable = true;
  boot.kernelParams = lib.optionals tuneGtt [
    "amdgpu.gttsize=114688"
    "ttm.pages_limit=29360128"
    "ttm.page_pool_size=29360128"
  ];

  users.users.qwen-flash-next = {
    isSystemUser = true;
    group = "qwen-flash-next";
    home = "/var/lib/qwen-flash-next";
  };
  users.groups.qwen-flash-next = { };
  systemd.tmpfiles.rules = [
    "d /var/lib/qwen-flash-next 0755 qwen-flash-next qwen-flash-next -"
    "d ${modelStore} 0755 qwen-flash-next qwen-flash-next -"
  ];

  systemd.services.qwen-flash-next = {
    description = "Qwen3.8-Flash-Next 177B IQ4_NL (pwilkin HIP, gfx1151)";
    after = [
      "network.target"
      "qwen-flash-next-models.service"
    ];
    # Boot starts the service normally. The preflight keeps it stopped until
    # the exact nine-shard manifest is complete; reconciliation starts it.
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      StartLimitIntervalSec = 3600;
      StartLimitBurst = 3;
    };
    environment = requiredEnvironment;
    serviceConfig = {
      Type = "simple";
      User = "qwen-flash-next";
      Group = "qwen-flash-next";
      StateDirectory = "qwen-flash-next";
      SupplementaryGroups = [
        "video"
        "render"
      ];
      ExecStartPre = hostPreflight;
      ExecStart = "${memoryGuard} ${lib.escapeShellArgs serverArgs}";
      ExecStartPost = readiness;
      Restart = "on-failure";
      RestartSec = 60;
      TimeoutStartSec = "50min";
      TimeoutStopSec = "5min";
      MemoryAccounting = true;
      MemorySwapMax = 0;
      OOMPolicy = "stop";
      OOMScoreAdjust = 500;
    };
  };

  systemd.timers.qwen-flash-next-models = lib.mkIf provisionModel {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "24h";
      RandomizedDelaySec = "30min";
    };
  };
  systemd.services.qwen-flash-next-models = lib.mkIf provisionModel {
    description = "Reconcile exact Qwen3.8-Flash-Next IQ4_NL shards";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    unitConfig.OnSuccess = [ "qwen-flash-next.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "qwen-flash-next";
      Group = "qwen-flash-next";
      ExecStart = reconcileScript;
      TimeoutStartSec = "12h";
    };
  };

  # The backend is loopback-only. Fort nginx is the existing VPN/token ingress;
  # no new firewall opening or public listener is introduced.
  fort.cluster.services = [
    {
      name = serviceName;
      inherit port subdomain;
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
  ];
}
