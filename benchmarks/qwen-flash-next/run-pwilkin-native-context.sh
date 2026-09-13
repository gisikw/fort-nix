#!/usr/bin/env bash
# Bounded native-context qualification using the retained, verified pwilkin stack.
# Run one arm at a time so the 131072 result can gate the 262144 arm.
set -Eeuo pipefail
umask 077
B=${WORK:-/var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d}
IMAGE=${IMAGE:-localhost/strix-halo-rocm10-runtime:545cf48d}
RENDER_NODE=${RENDER_NODE:-/dev/dri/renderD128}
LIMIT=${1:?native context limit required (131072 or 262144)}
case "$LIMIT" in
  131072) PP_DEPTH=114688; TG_DEPTH=130944 ;;
  262144) PP_DEPTH=245760; TG_DEPTH=262016 ;;
  *) echo "unsupported native context limit: $LIMIT" >&2; exit 64 ;;
esac
TAG="native-${LIMIT}"
NAME="strix-halo-${TAG}-$$"
P=(nix shell nixpkgs#podman -c podman --root "$B/podman-root" --runroot "$B/podman-runroot")
START=
BASE_SWAP_FREE=
BASE_PSWPOUT=
restore() {
  set +e
  "${P[@]}" rm -f "$NAME" >/dev/null 2>&1
  systemctl unmask --runtime ollama.service >/dev/null 2>&1
  systemctl start ollama.service
  systemctl start ollama-dashboard.service
  systemctl start qwen-flash-next.service
  systemctl start ollama-models.timer
  systemctl start qwen-flash-next-models.timer
  for _ in {1..450}; do
    curl -fsS --max-time 2 http://127.0.0.1:8014/health >/dev/null 2>&1 && break
    sleep 2
  done
  {
    echo "restore_utc=$(date -u +%FT%TZ)"
    printf 'qwen_health='; curl -fsS --max-time 5 http://127.0.0.1:8014/health; echo
    printf 'ollama_version='; curl -fsS --max-time 5 http://127.0.0.1:11434/api/version; echo
    systemctl is-active qwen-flash-next.service ollama.service ollama-dashboard.service qwen-flash-next-models.timer ollama-models.timer
    systemctl --failed --no-pager
    echo "boot_id_restore=$(cat /proc/sys/kernel/random/boot_id)"
    echo 'listeners_restore:'
    ss -ltnp | grep -E ':(8014|11434|18014)\b' || true
    echo 'qwen_argv_restore:'
    tr '\0' ' ' < "/proc/$(systemctl show -p MainPID --value qwen-flash-next.service)/cmdline"; echo
    echo "qwen_exe_restore=$(readlink -f /proc/$(systemctl show -p MainPID --value qwen-flash-next.service)/exe)"
  } >> "$B/${TAG}-window.txt" 2>&1
}
trap restore EXIT INT TERM

# Capture the healthy production state before stopping any service.
systemctl start qwen-flash-next-models.service
for _ in {1..60}; do systemctl is-active --quiet qwen-flash-next-models.service || break; sleep 1; done
START=$(date -u +%FT%T.%NZ)
{
  echo "start_utc=$START"
  echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
  echo "limit=$LIMIT"
  echo "pp_depth=$PP_DEPTH pp_end=$((PP_DEPTH + 16384))"
  echo "tg_depth=$TG_DEPTH tg_end=$((TG_DEPTH + 128))"
  grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
  systemctl is-active qwen-flash-next.service ollama.service ollama-dashboard.service qwen-flash-next-models.timer ollama-models.timer
  systemctl --failed --no-pager
  printf 'qwen_health='; curl -fsS --max-time 5 http://127.0.0.1:8014/health; echo
  printf 'ollama_version='; curl -fsS --max-time 5 http://127.0.0.1:11434/api/version; echo
  echo 'qwen_argv_before:'
  tr '\0' ' ' < "/proc/$(systemctl show -p MainPID --value qwen-flash-next.service)/cmdline"; echo
  echo "qwen_exe_before=$(readlink -f /proc/$(systemctl show -p MainPID --value qwen-flash-next.service)/exe)"
} > "$B/${TAG}-window.txt"

systemctl stop qwen-flash-next-models.timer ollama-models.timer
systemctl stop ollama-models.service qwen-flash-next-models.service || true
systemctl stop qwen-flash-next.service ollama-dashboard.service ollama.service
systemctl mask --runtime ollama.service

GPUDEV=
for device in /sys/class/drm/card*/device; do
  if [[ -r $device/mem_info_gtt_total ]]; then GPUDEV=$device; break; fi
done
[[ -n $GPUDEV ]] || { echo 'amdgpu memory counters unavailable' >&2; exit 1; }
BASE_SWAP_FREE=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
BASE_PSWPOUT=$(awk '$1=="pswpout"{print $2}' /proc/vmstat)
printf 'epoch_s MemAvailable_kB SwapFree_kB pswpin_pages pswpout_pages vram_used_B gtt_used_B llama_rss_kB psi_mem_some_avg10 psi_mem_full_avg10\n' > "$B/${TAG}-memory.tsv"
monitor() {
  while kill -0 "$1" 2>/dev/null; do
    ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    pi=$(awk '$1=="pswpin"{print $2}' /proc/vmstat)
    po=$(awk '$1=="pswpout"{print $2}' /proc/vmstat)
    vr=$(cat "$GPUDEV/mem_info_vram_used")
    gt=$(cat "$GPUDEV/mem_info_gtt_used")
    lp=$(pgrep -n llama-bench || true); rss=0
    [[ -z $lp ]] || rss=$(awk '/^VmRSS:/{print $2}' "/proc/$lp/status" 2>/dev/null || echo 0)
    read -r ps pf < <(awk '/^some/{for(i=1;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");s=a[2]}} /^full/{for(i=1;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");f=a[2]}} END{print s+0,f+0}' /proc/pressure/memory)
    printf '%s %s %s %s %s %s %s %s %s %s\n' "$(date +%s)" "$ma" "$sf" "$pi" "$po" "$vr" "$gt" "${rss:-0}" "$ps" "$pf" >> "$B/${TAG}-memory.tsv"
    reason=
    if (( ma < 8388608 )); then reason="memory_guard_MemAvailable_kB=$ma"
    elif (( BASE_SWAP_FREE - sf > 2097152 )); then reason="swap_guard_consumed_kB=$((BASE_SWAP_FREE - sf))"
    elif (( po - BASE_PSWPOUT > 524288 )); then reason="swap_guard_pswpout_pages=$((po - BASE_PSWPOUT))"
    elif journalctl -k -b --since "$START" --no-pager -n 150 2>/dev/null | grep -Eqi 'amdgpu.*(GPU reset|ring .*timeout|fault|failed)|kfd.*(fault|reset)|oom-kill|Out of memory|Killed process'; then reason=kernel_fault_guard
    fi
    if [[ -n $reason ]]; then
      echo "$reason" >> "$B/${TAG}-window.txt"
      "${P[@]}" kill "$NAME" >/dev/null 2>&1 || true
      break
    fi
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
    -e PP_DEPTH="$PP_DEPTH" -e TG_DEPTH="$TG_DEPTH" -e LIMIT="$LIMIT" \
    "$IMAGE" bash -ceu '
      BIN=/bench/work/build/llama.cpp/bin
      export PATH=/opt/rocm/bin:$PATH
      export LD_LIBRARY_PATH=/bench/work/runtime/hip/lib:/bench/work/runtime/rocr/lib:/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/llvm/lib:$BIN
      common=(-m Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf -dev ROCm0 -ngl 999 -fa on -ctk f16 -ctv f16 -lm none -lzm on-direct -b 16384 -ub 16384 -r 3 -o json)
      t0=$(date +%s.%N)
      "$BIN/llama-bench" "${common[@]}" -p 16384 -n 0 -d "$PP_DEPTH" > "/bench/native-${LIMIT}-pp.json"
      t1=$(date +%s.%N)
      printf "pp_start_s=%s\npp_end_s=%s\n" "$t0" "$t1" > "/bench/native-${LIMIT}-timing.txt"
      "$BIN/llama-bench" "${common[@]}" -p 0 -n 128 -d "$TG_DEPTH" > "/bench/native-${LIMIT}-tg.json"
      t2=$(date +%s.%N)
      printf "tg_start_s=%s\ntg_end_s=%s\n" "$t1" "$t2" >> "/bench/native-${LIMIT}-timing.txt"
    '
) 9>"$B/gpu.lock" >"$B/${TAG}-stdout.log" 2>"$B/${TAG}-stderr.log" &
runpid=$!
monitor "$runpid" & monpid=$!
set +e
wait "$runpid"; rc=$?
wait "$monpid" || true
set -e
END=$(date -u +%FT%T.%NZ)
printf 'end_utc=%s\nrc=%s\nboot_id_end=%s\n' "$END" "$rc" "$(cat /proc/sys/kernel/random/boot_id)" | tee -a "$B/${TAG}-window.txt"
# Keep the complete bounded slice: non-GPU kernel warnings under memory pressure
# are relevant too, and a grep can otherwise retain only misleading module lists.
journalctl -k -b --since "$START" --until "$END" --no-pager > "$B/${TAG}-kernel.log" || true
exit "$rc"
