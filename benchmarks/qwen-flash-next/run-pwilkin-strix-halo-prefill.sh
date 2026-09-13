#!/usr/bin/env bash
# Bounded lordhenry reproduction using an already-built/verified retained tree.
# This deliberately does not download, build, deploy, or alter persistent units.
set -Eeuo pipefail
umask 077
B=${WORK:-/var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d}
IMAGE=${IMAGE:-localhost/strix-halo-rocm10-runtime:545cf48d}
RENDER_NODE=${RENDER_NODE:-/dev/dri/renderD128}
BATCH=${1:?batch required (24576 or 16384)}
case "$BATCH" in 24576|16384) ;; *) echo "unsupported batch: $BATCH" >&2; exit 64;; esac
TAG="resume-b${BATCH}"
NAME="strix-halo-${TAG}-$$"
P=(nix shell nixpkgs#podman -c podman --root "$B/podman-root" --runroot "$B/podman-runroot")
restore() {
  set +e
  "${P[@]}" rm -f "$NAME" >/dev/null 2>&1
  systemctl unmask --runtime ollama.service >/dev/null 2>&1
  systemctl start ollama.service
  systemctl start ollama-dashboard.service
  systemctl start qwen-flash-next.service
  systemctl start ollama-models.timer
  systemctl start qwen-flash-next-models.timer
  for i in {1..450}; do curl -fsS --max-time 2 http://127.0.0.1:8014/health >/dev/null 2>&1 && break; sleep 2; done
  {
    echo "restore_utc=$(date -u +%FT%TZ)"
    printf 'qwen_health='; curl -fsS --max-time 5 http://127.0.0.1:8014/health; echo
    printf 'ollama_version='; curl -fsS --max-time 5 http://127.0.0.1:11434/api/version; echo
    systemctl is-active qwen-flash-next.service ollama.service ollama-dashboard.service qwen-flash-next-models.timer ollama-models.timer
    systemctl --failed --no-pager
    echo "boot_id_restore=$(cat /proc/sys/kernel/random/boot_id)"
  } >> "$B/${TAG}-window.txt" 2>&1
}
trap restore EXIT INT TERM
START=$(date -u +%FT%TZ)
printf 'start_utc=%s\nboot_id=%s\nbatch=%s\n' "$START" "$(cat /proc/sys/kernel/random/boot_id)" "$BATCH" | tee "$B/${TAG}-window.txt"
systemctl stop qwen-flash-next-models.timer ollama-models.timer
systemctl stop ollama-models.service qwen-flash-next-models.service || true
systemctl stop qwen-flash-next.service ollama-dashboard.service ollama.service
systemctl mask --runtime ollama.service
printf 'epoch_s MemAvailable_kB vram_used_B gtt_used_B llama_rss_kB\n' > "$B/${TAG}-memory.tsv"
GPUDEV=
for device in /sys/class/drm/card*/device; do
  if [[ -r $device/mem_info_gtt_total ]]; then GPUDEV=$device; break; fi
done
[[ -n $GPUDEV ]] || { echo 'amdgpu memory counters unavailable' >&2; exit 1; }
monitor() {
  while kill -0 "$1" 2>/dev/null; do
    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    vr=$(cat "$GPUDEV/mem_info_vram_used")
    gt=$(cat "$GPUDEV/mem_info_gtt_used")
    lp=$(pgrep -n llama-bench || true); rss=0
    [ -z "$lp" ] || rss=$(awk '/^VmRSS:/{print $2}' "/proc/$lp/status" 2>/dev/null || echo 0)
    printf '%s %s %s %s %s\n' "$(date +%s)" "$ma" "$vr" "$gt" "${rss:-0}" >> "$B/${TAG}-memory.tsv"
    if [ "$ma" -lt 8388608 ]; then echo "memory_guard_MemAvailable_kB=$ma" >> "$B/${TAG}-window.txt"; "${P[@]}" kill "$NAME" >/dev/null 2>&1 || true; break; fi
    sleep 1
  done
}
export HOME="$B/home"
(
  flock -n 9 || { echo 'GPU lock busy' >&2; exit 75; }
  "${P[@]}" run --name "$NAME" --rm --security-opt label=disable --network=none --ipc=host \
    --device /dev/kfd --device "$RENDER_NODE" -v "$B:/bench" -w /bench/models \
    -e HSA_OVERRIDE_GFX_VERSION=11.5.1 -e GGML_HIP_ENABLE_UNIFIED_MEMORY=1 -e GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 \
    -e ENABLE_RETAINED_PM4=1 -e DEBUG_HIP_GRAPH_PM4=1 \
    -e LLAMA_MMB=1 -e LLAMA_MMB_MIN_T=512 -e LLAMA_MMB_BF16W=1 -e LLAMA_MMB_GLU=1 \
    -e LLAMA_MMB_TALL=2 -e LLAMA_MMB_CACHE=4 -e LLAMA_MMB_F32SPLIT=2 -e LLAMA_MMB_HC16=2 \
    -e LLAMA_MMB_SHADOW=2 -e LLAMA_MMB_DOWN16=1 -e LLAMA_HC_CN_SHAPE=1 -e LLAMA_HC_GATEMIX=1 \
    -e LLAMA_HC_MIX_FUSE=1 -e LLAMA_HC_BLK16=1 -e LLAMA_HC_RES16=1 -e LLAMA_HC_PACK_DI=1 \
    -e LLAMA_NORM_GATED=1 -e LLAMA_NORM_ROWS=1 -e LLAMA_IDX_RELU_SUM=1 -e LLAMA_PLE_CONV=1 \
    -e LLAMA_GDN_CONV=1 -e LLAMA_QSA_SPARSE=1 -e LLAMA_QSA_WHOLE_ATTN=1 \
    -e LLAMA_QSA_BLOCK_SELECTION=1 -e LLAMA_QSA_COMPACT_METADATA=1 -e LLAMA_QSA_DENSE_SHORTCUT=1 \
    -e LLAMA_QSA_DIRECT_INDICES=1 -e LLAMA_QSA_PACK_KEYS=1 -e LLAMA_QSA_PACK_VALUES=1 \
    -e LLAMA_QSA_QUERY_STRIP=512 -e LLAMA_QSA_SCORE_BOUNDS=1 -e LLAMA_QSA_NO_DENSE_MASK=1 \
    -e LLAMA_QSA_FA_V3=1 -e LLAMA_QSA_FUSE_EXPAND=1 -e LLAMA_MTP_QSA=1 -e LLAMA_MTP_QSA_MIN_T=128 \
    "$IMAGE" bash -ceu '
      BIN=/bench/work/build/llama.cpp/bin
      export PATH=/opt/rocm/bin:$PATH
      export LD_LIBRARY_PATH=/bench/work/runtime/hip/lib:/bench/work/runtime/rocr/lib:/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/llvm/lib:$BIN
      exec "$BIN/llama-bench" -m Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf -dev ROCm0 -ngl 999 -fa on -ctk f16 -ctv f16 -lm none -lzm on-direct -b '"$BATCH"' -ub '"$BATCH"' -p 16384 -n 128 -d 0,40000 -r 3
    '
) 9>"$B/gpu.lock" >"$B/${TAG}-stdout.log" 2>"$B/${TAG}-stderr.log" &
runpid=$!
monitor "$runpid" & monpid=$!
set +e
wait "$runpid"; rc=$?
wait "$monpid" || true
set -e
END=$(date -u +%FT%TZ)
printf 'end_utc=%s\nrc=%s\nboot_id_end=%s\n' "$END" "$rc" "$(cat /proc/sys/kernel/random/boot_id)" | tee -a "$B/${TAG}-window.txt"
journalctl -k -b --since "$START" --until "$END" --no-pager | grep -Ei 'amdgpu|kfd|oom|out of memory|ring|reset|xnack|mes' > "$B/${TAG}-kernel.log" || true
exit "$rc"
