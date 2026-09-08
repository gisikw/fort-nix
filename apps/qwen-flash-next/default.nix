# Qwen3.8-Flash-Next on AMD Strix Halo (lordhenry).
#
# 180B total / ~6B active: 125B MoE body + 51B PLE n-gram embedding + 4B MTP
# head, hybrid Gated DeltaNet + Qwen Sparse Attention, 262144 native context.
# Served by a pinned Vulkan llama.cpp build (pkgs/llama-cpp-halo).
#
# READ apps/qwen-flash-next/README.md BEFORE CHANGING ANYTHING HERE. It carries
# the memory budget, state-persistence findings, and measured slot trade-offs.
#
# The hybrid Gated DeltaNet layers hold recurrent R/S state and PLE convolution
# history in addition to sparse-attention KV/indexer data. As of the pinned
# b10840 source, llama.cpp's sequence-state serializer includes all of those
# components; KV-only persistence would be invalid, but full slot persistence
# is architecturally implemented. This deployment does not expose disk slot
# save/restore or the RAM prompt cache: continuity is intentionally in-process.
{
  subdomain ? null,
  serviceName ? "qwen-next",
  port ? 8014,
  # Quant selection. Default UD-Q3_K_XL: 83.8 GiB of weights, the largest rung
  # that leaves working room on a 128 GB unified-memory box that also hosts
  # ollama. See README § Quant ladder for the fallbacks and their sizes.
  quant ? "UD-Q3_K_XL",
  # Server slots. Production uses one slot after benchmarking the two-slot
  # shadow-prefill design; callers can still raise this for explicit testing.
  slots ? 1,
  # TOTAL context across all slots; llama.cpp divides it by `slots` when the KV
  # cache is not unified. 131072 with one slot gives one 131072-token context.
  # The model supports 262144 natively; raise only after measuring headroom.
  contextSize ? 131072,
  # Context checkpoints per slot. These are what let a trajectory rewind to an
  # earlier point (e.g. when the coordinator swaps a skill block out of the
  # transcript) without re-prefilling from token zero.
  ctxCheckpoints ? 8,
  checkpointMinStep ? 4096,
  # Keep the PLE (n-gram embedding) tensors in host memory. They are a large,
  # sparsely-touched lookup table; leaving them mmap-backed on the CPU side
  # keeps the GPU allocation down and lets the page cache evict cold rows.
  # Set to null to place everything on the GPU.
  ngramOverrideTensor ? "ple_key|ple_value=CPU",
  # MTP speculative decoding. OFF by default: mainline llama.cpp has no MTP
  # graph for the `qwen4exp` architecture yet (ggml-org/llama.cpp#28243 is
  # still open as of 2026-09-07), so the drafter would be a 2.6 GiB download
  # that does nothing. Flip on together with a source pin that carries the PR.
  enableMtp ? false,
  # Raise the amdgpu/TTM limits so an 84 GiB model can live in GTT on a
  # 128 GB unified-memory APU. Takes effect on the next REBOOT.
  tuneGtt ? true,
  # Managed provisioning. When false the model store is left alone entirely
  # (no downloads, no timer) — useful to stage the unit before capacity exists.
  provisionModel ? true,
  ...
}:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  llamaHalo = import ../../pkgs/llama-cpp-halo { inherit pkgs; };

  repo = "unsloth/Qwen3.8-Flash-Next-GGUF";
  modelStore = "/var/lib/qwen-flash-next/models";
  modelAlias = "Qwen3.8-Flash-Next";

  # sha256 values are the Hugging Face LFS oids, read from the model tree API
  # on 2026-09-07. Sizes are exact bytes and drive the capacity precheck.
  quants = {
    "UD-Q3_K_XL" = [
      {
        file = "Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf";
        size = 10946624;
        sha256 = "f2ef4328929d8b8c8930e2856eef52128dd4ce3425302f04bc3c657431cc4c49";
      }
      {
        file = "Qwen3.8-Flash-Next-UD-Q3_K_XL-00002-of-00003.gguf";
        size = 49983253824;
        sha256 = "7d230e7c9421d868b89eebaf23033af0ea1a4e046956df00fb156814fb62346e";
      }
      {
        file = "Qwen3.8-Flash-Next-UD-Q3_K_XL-00003-of-00003.gguf";
        size = 39992153376;
        sha256 = "21d4f90f9cd7b7c3a1582667c20cb22f7b03de895b88a23bb20aaeaa44f2c199";
      }
    ];
    "UD-IQ3_XXS" = [
      {
        file = "Qwen3.8-Flash-Next-UD-IQ3_XXS-00001-of-00003.gguf";
        size = 10946624;
        sha256 = "268f81fdedf3149a538f252308927a4d5d1f6e062c178568a51e3b519744f8a8";
      }
      {
        file = "Qwen3.8-Flash-Next-UD-IQ3_XXS-00002-of-00003.gguf";
        size = 49567921344;
        sha256 = "cfe600b236b88c7fad1613a5ca5e83b9f2beb63cbd44c32b2be50a44747c695f";
      }
      {
        file = "Qwen3.8-Flash-Next-UD-IQ3_XXS-00003-of-00003.gguf";
        size = 32382955968;
        sha256 = "f1912ba34c79427d2295a58dcb2b732b5931af5bef7a373c60557a57d9ee7250";
      }
    ];
  };

  mtpArtifact = {
    file = "mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf";
    subdir = "MTP";
    size = 2786568256;
    sha256 = "5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6";
  };

  shards = quants.${quant};
  firstShard = builtins.head shards;

  artifacts = (map (a: a // { subdir = quant; }) shards) ++ lib.optional enableMtp mtpArtifact;

  artifactsJson = builtins.toJSON (
    map (a: {
      inherit (a)
        file
        size
        sha256
        subdir
        ;
    }) artifacts
  );

  totalBytes = lib.foldl' (acc: a: acc + a.size) 0 artifacts;
  # Headroom on top of the artifacts: partial-download slack plus room for the
  # host's own churn. Refuse to start downloading below this.
  marginBytes = 16 * 1024 * 1024 * 1024;

  # Managed provisioning with a capacity precheck. This unit will NOT start a
  # ~90 GB download onto a filesystem that cannot hold it; it logs the exact
  # shortfall and exits non-zero so the timer retries after space is freed.
  reconcileScript = pkgs.writeShellScript "qwen-flash-next-reconcile" ''
    set -uo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ]
    }:$PATH

    STORE="${modelStore}"
    mkdir -p "$STORE"

    # ---- capacity gate -------------------------------------------------
    needed=0
    count=$(jq 'length' <<< '${artifactsJson}')
    for i in $(seq 0 $((count - 1))); do
      file=$(jq -r ".[$i].file" <<< '${artifactsJson}')
      size=$(jq -r ".[$i].size" <<< '${artifactsJson}')
      have=$(stat -c %s "$STORE/$file" 2>/dev/null || echo 0)
      if [ "$have" != "$size" ]; then
        needed=$((needed + size - $(stat -c %s "$STORE/$file.downloading" 2>/dev/null || echo 0)))
      fi
    done

    if [ "$needed" -gt 0 ]; then
      avail=$(($(stat -f -c '%a * %S' "$STORE")))
      required=$((needed + ${toString marginBytes}))
      if [ "$avail" -lt "$required" ]; then
        echo "BLOCKED: need $((required / 1024 / 1024 / 1024)) GiB free under $STORE" \
             "(artifacts $((needed / 1024 / 1024 / 1024)) GiB + 16 GiB margin)," \
             "have $((avail / 1024 / 1024 / 1024)) GiB. Not downloading." >&2
        exit 1
      fi
      echo "Capacity OK: $((avail / 1024 / 1024 / 1024)) GiB free," \
           "$((needed / 1024 / 1024 / 1024)) GiB to fetch."
    fi

    # ---- fetch + verify ------------------------------------------------
    failed=0
    for i in $(seq 0 $((count - 1))); do
      file=$(jq -r ".[$i].file" <<< '${artifactsJson}')
      subdir=$(jq -r ".[$i].subdir" <<< '${artifactsJson}')
      want=$(jq -r ".[$i].sha256" <<< '${artifactsJson}')

      target="$STORE/$file"
      partial="$STORE/$file.downloading"
      url="https://huggingface.co/${repo}/resolve/main/$subdir/$file"

      if [ -f "$target" ]; then
        actual=$(sha256sum "$target" | cut -d' ' -f1)
        if [ "$actual" = "$want" ]; then
          echo "OK: $file"
          continue
        fi
        echo "WARN: $file hash mismatch; removing." >&2
        rm -f "$target"
      fi

      if [ -f "$partial" ]; then
        actual=$(sha256sum "$partial" | cut -d' ' -f1)
        if [ "$actual" = "$want" ]; then
          mv "$partial" "$target"
          echo "DONE: $file (validated partial)"
          continue
        fi
      fi

      echo "Downloading $file"
      if ! curl -C - -L --fail --retry 3 --retry-delay 15 --connect-timeout 30 \
           -o "$partial" "$url"; then
        echo "ERROR: download failed for $file; retrying next cycle." >&2
        failed=$((failed + 1))
        continue
      fi

      actual=$(sha256sum "$partial" | cut -d' ' -f1)
      if [ "$actual" != "$want" ]; then
        echo "ERROR: hash mismatch for $file (want $want, got $actual); deleting." >&2
        rm -f "$partial"
        failed=$((failed + 1))
        continue
      fi
      mv "$partial" "$target"
      echo "DONE: $file"
    done

    if [ "$failed" -gt 0 ]; then
      echo "$failed artifact(s) outstanding." >&2
      exit 1
    fi
    echo "Artifact reconciliation complete ($((${toString totalBytes} / 1024 / 1024 / 1024)) GiB)."
  '';

  serverArgs = [
    "${llamaHalo}/bin/llama-server"
    # Loopback only: the sole ingress is this host's nginx (see
    # fort.cluster.services below). Nothing else may reach the API.
    "--host 127.0.0.1"
    "--port ${toString port}"
    "--model ${modelStore}/${firstShard.file}"
    "--alias ${modelAlias}"
    "--jinja"
    "--gpu-layers 999"
    "--flash-attn auto"
    "--parallel ${toString slots}"
    # Keep allocation and affinity behavior explicit. With one slot this is
    # equivalent in capacity to unified KV.
    "--no-kv-unified"
    "--ctx-size ${toString contextSize}"
    # In-process rewind points. NOT a disk cache: see the header comment.
    "--ctx-checkpoints ${toString ctxCheckpoints}"
    "--checkpoint-min-step ${toString checkpointMinStep}"
    # Prefix reuse within the resident conversation.
    "--cache-prompt"
    "--cache-reuse 256"
    # Keep persistence disabled operationally: no RAM prompt cache, idle-slot
    # spill, or --slot-save-path. The pinned serializer does include recurrent
    # state, but it has not been enabled or end-to-end qualified here.
    "--cache-ram 0"
    "--no-cache-idle-slots"
    # Preserve the existing fail-at-the-bound policy. The pinned memory module
    # reports shift support, but production has not qualified long-run shifts.
    "--no-context-shift"
    "--metrics"
  ]
  ++ lib.optional (ngramOverrideTensor != null) "--override-tensor \"${ngramOverrideTensor}\""
  ++ lib.optionals enableMtp [
    "--spec-draft-model ${modelStore}/${mtpArtifact.file}"
    "--spec-type draft-mtp"
    "--spec-draft-n-max 2"
  ];
in
{
  assertions = [
    {
      assertion = builtins.hasAttr quant quants;
      message = "qwen-flash-next: unknown quant '${quant}' (have: ${lib.concatStringsSep ", " (builtins.attrNames quants)})";
    }
    {
      assertion = slots >= 1;
      message = "qwen-flash-next: slots must be at least one";
    }
  ];

  hardware.graphics.enable = true;

  # Unified memory: without raising the TTM/GTT ceiling the GPU can only map
  # about half of RAM and an 84 GiB model will not fit. Reboot to apply.
  boot.kernelParams = lib.optionals tuneGtt [
    "amdgpu.gttsize=114688" # MiB (112 GiB)
    "ttm.pages_limit=29360128" # 4 KiB pages (112 GiB)
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
    description = "Qwen3.8-Flash-Next (llama.cpp/Vulkan, Strix Halo)";
    after = [ "network.target" ];
    # Never started by activation: an 84 GiB model that is not on disk yet
    # would crash-loop and fail the switch. The reconciler starts it once every
    # artifact is present and verified.
    wantedBy = [ ];

    unitConfig.ConditionPathExists = "${modelStore}/${firstShard.file}";

    serviceConfig = {
      Type = "simple";
      User = "qwen-flash-next";
      Group = "qwen-flash-next";
      StateDirectory = "qwen-flash-next";
      SupplementaryGroups = [
        "video"
        "render"
      ];
      ExecStart = lib.concatStringsSep " " serverArgs;
      Restart = "on-failure";
      RestartSec = 30;
      # Loading ~84 GiB off disk into GTT is slow on first (cold cache) start.
      TimeoutStartSec = "45min";
      TimeoutStopSec = "5min";
    };
  };

  systemd.timers.qwen-flash-next-models = lib.mkIf provisionModel {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
    };
  };

  systemd.services.qwen-flash-next-models = lib.mkIf provisionModel {
    description = "Reconcile Qwen3.8-Flash-Next GGUF artifacts (${quant})";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Multi-hour downloads must never be attached to a switch.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = "qwen-flash-next";
      Group = "qwen-flash-next";
      ExecStart = reconcileScript;
      # Start (or restart) the server once the store is complete. Runs as root;
      # --no-block avoids a deadlock against this unit's own ordering.
      ExecStartPost = "+${pkgs.systemd}/bin/systemctl restart --no-block qwen-flash-next.service";
      TimeoutStartSec = "infinity";
    };
  };

  # Private API: no `visibility` key means VPN-only, and the backend itself is
  # bound to loopback. Token SSO on top so mesh-resident services still have to
  # present a credential.
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
