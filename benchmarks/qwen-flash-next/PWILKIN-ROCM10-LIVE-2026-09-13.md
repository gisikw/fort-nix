# pwilkin Strix Halo / ROCm 10 live qualification — lordhenry

Date: 2026-09-13 UTC. Plate: `545cf48d-88be-4419-9f99-14a602ebfce8`.

## Disposition

The recovered 1,086–1,204 prompt-token/s source is pwilkin's Strix Halo stack,
not EngramHalo.cpp. The exact source/runtime/weights were pinned, built and
verified. The first boot's adjustable 64 GiB UMA carveout prevented the managed
weight allocation; after the owner changed UMA to 2 GiB and rebooted, the exact
stack loaded and completed every requested three-repetition prefill case.
Functional reproduction therefore succeeds. After the completed native-context
arm below, the owner accepted this evidence and selected the exact no-MTP stack
as Fort's declarative production candidate; rollback is by git revert. The
published absolute rates did not reproduce on lordhenry: the installed-default
16384 batch reached
1065.76 ± 5.97 prompt t/s at depth zero rather than 1204.31 ± 2.31. The
published MTP server configuration loaded, but its first bounded decode exposed
a correctness failure and was not repeated. Production was restored without a
deployment or persistent configuration change.

Authoritative sources:

* <https://pwilkin.github.io/strix-halo/>
* <https://pwilkin.github.io/strix-halo/journey.html>
* installer snapshot `pwilkin/strix-halo@98bc5b2a2a8009543c167a31f80b9dbb2aa90e33`
* custom ROCr/HIP `pwilkin/rocm-systems@7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1`
* engine `pwilkin/llama.cpp@f5daaa3cfa6358e5dd398911ec741813745a5440`
* AMD image `docker.io/rocm/dev-ubuntu-24.04@sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374`

The journey's exact command is:

```text
llama-bench -m Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf
  -dev ROCm0 -ngl 999 -fa on -ctk f16 -ctv f16
  -lm none -lzm on-direct -b 24576 -ub 24576
  -p 16384 -n 128 -d 0,40000 -r 3
```

The final launcher kernel gates were exported. Unified memory, gfx1151 and the
custom retained-PM4 ROCr/HIP runtime were enabled. Retained PM4 cannot carry
these one-off prefill shapes, as the source itself documents; its presence is
stack fidelity, not an explanation of prefill throughput.

## Resumed boot and measurements

The owner changed the BIOS UMA reservation from 64 GiB to 2 GiB and rebooted.
The resumed boot was `60093145-c25f-4f3f-b3af-cc931f6717f2`, with
`MemTotal=129,465,768 KiB`, 2,147,483,648 bytes VRAM and 120,259,084,288 bytes
GTT. Kernel, NixOS, amdgpu/TTM limits, CWSR/MES settings and device permissions
were otherwise unchanged. Before stopping anything, the normal
`qwen-flash-next-models.service` reconciliation was explicitly started. The
production b10840 executable and full argv matched the prior baseline, port
8014 `/health` and Ollama `/api/version` returned HTTP 200, both model timers
were active and there were no failed units.

All nine model shards, the MTP sidecar, both executables and both custom runtime
libraries were re-hashed after reboot and matched the values below. Both source
trees were clean at their pinned commits. The retained runtime image was still
based on AMD image digest `a90cf047…` and no download or rebuild occurred.

The exact journey command, launcher gates, custom ROCr/HIP and corrected
`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` completed with return code zero. The first
post-reboot execution reported 1079.39 ± 3.68 pp and 27.98 ± 0.11 tg at depth
zero, then 1026.83 ± 8.40 pp and 18.14 ± 0.06 tg at depth 40000. Its benchmark
was sound, but a card-number bug left its memory monitor empty. One intervening
monitor-repair replay also returned zero but its output was overwritten; no
rate is claimed from it. The corrected, fully monitored replay and subsequent
16384 confirmation reported:

| batch / ubatch | test | result (three repetitions) |
|---:|---|---:|
| 24576 | pp16384, depth 0 | **1068.74 ± 7.68 t/s** |
| 24576 | tg128, depth 0 | **27.89 ± 0.02 t/s** |
| 24576 | pp16384, depth 40000 | **1016.12 ± 5.51 t/s** |
| 24576 | tg128, depth 40000 | **17.98 ± 0.03 t/s** |
| 16384 | pp16384, depth 0 | **1065.76 ± 5.97 t/s** |
| 16384 | tg128, depth 0 | **27.97 ± 0.13 t/s** |
| 16384 | pp16384, depth 40000 | **1019.24 ± 5.59 t/s** |
| 16384 | tg128, depth 40000 | **18.00 ± 0.08 t/s** |

Thus the source's useful conclusion that 16384 loses nothing to 24576 did
reproduce, as did stable lazy direct placement at both depths. Its published
1204.31 ± 2.31 default-batch depth-zero and 1086.29 ± 0.96 depth-40000 means
did not: lordhenry reached 88.5% and 93.8% respectively. These are full means
and spreads reported by `llama-bench`, not best-of values. `llama-bench` does
not expose generated token IDs, so completion of all repetitions establishes
execution stability but is not an independent semantic-correctness test.

The corrected one-second monitor recorded, for 24576, peak process RSS
104,516,772 KiB and minimum `MemAvailable` 21,647,328 KiB; for 16384 the values
were 93,381,240 KiB and 33,257,832 KiB. The observed RSS reduction was
11,135,532 KiB (10.62 GiB). Sysfs VRAM/GTT peaks were only 170,569,728 and
217,346,048 bytes because the dominant managed allocation was resident system
memory rather than a TTM-accounted GTT buffer. The 8 GiB safety guard never
fired. Bounded kernel slices for both runs were empty: no reset, ring/MES fault,
XNACK event or kernel OOM occurred.

## Native-context qualification

A later bounded qualification on the same boot directly reached both the
approximately 131K point and the model's full native 262,144-token boundary.
No artifact was downloaded or rebuilt. Immediately before the window, all ten
published model hashes, `llama-bench`, `llama-server`, custom HIP and custom
ROCr were re-hashed successfully; both source trees were clean at their pins.
The production b10840 process/argv, both health endpoints, topology, kernel and
boot ID also matched the resumed baseline.

Pinned-source semantics matter here. `README.md` lines 85--95 define `-p` and
`-n` as separate pp and tg tests and `-d` as the KV prefill before *each* test.
`llama-bench.cpp` constructs separate instances (`n_gen=0` for pp and
`n_prompt=0` for tg, lines 1339--1410), sizes each context as
`n_depth+n_prompt+n_gen` (line 1293), performs the depth run before starting the
test timer (lines 2404--2464), and clears/restores state between repetitions.
Consequently, the earlier `pp16384 @ d40000` ends at 56,384, while the separate
`tg128 @ d40000` runs from 40,000 through 40,128; tg does **not** follow that
pp. The native tests therefore used distinct exact depths:

* pp: `114688 + 16384 = 131072` and `245760 + 16384 = 262144`;
* tg: `130944 + 128 = 131072` and `262016 + 128 = 262144`.

Each was a distinct `llama-bench` invocation with `-b 16384 -ub 16384`, FP16
K/V, three repetitions, no MTP, and otherwise the same engine, custom runtime,
lazy `on-direct` placement, launcher gates and
`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`. Thus the timed pp value is the final
16,384-token prefill chunk at the stated starting depth, not the time to build
the preceding depth. Likewise, each tg result includes its own unmeasured depth
prefill and is not a continuation of the pp test.

| boundary | independently timed test | mean ± spread | samples | mean timed duration |
|---:|---|---:|---|---:|
| 131,072 | pp16384 @ d114688 | **867.15 ± 4.15 t/s** | 862.384, 869.888, 869.189 | **18.894 s** |
| 131,072 | tg128 @ d130944 | **9.664 ± 0.022 t/s** | 9.68866, 9.65858, 9.64528 | **13.245 s** |
| 262,144 | pp16384 @ d245760 | **80.330 ± 0.048 t/s** | 80.2976, 80.3081, 80.3847 | **203.958 s** |
| 262,144 | tg128 @ d262016 | **5.315 ± 0.013 t/s** | 5.32299, 5.32312, 5.29972 | **24.082 s** |

The 131K arm occupied 426.45 seconds wall time (220.14 seconds for its complete
pp invocation and 205.05 seconds for tg, including model load, warmup and depth
construction). Its peak RSS was 97,738,620 KiB and minimum `MemAvailable` was
28,929,492 KiB (27.59 GiB), leaving 19.59 GiB above the live 8 GiB guard.
VRAM/GTT sysfs peaks were 170,369,024/218,562,560 bytes. Swap-free declined by
only 22,784 KiB and `pswpout` advanced 5,183 pages, not swap pathology. All
three samples were tight and both commands returned zero.

This supplied a positive progressive gate for the native maximum: even against
the observed rather than nominal arithmetic, 131K retained over twice the
required additional safety margin. One non-fatal kernel warning did occur
during Btrfs model readahead in the 131K tg invocation:
`prepare_slab_obj_exts_hook, biovec-max: Failed to create slab extension
vector!` from `alloc_tagging_slab_alloc_hook`. It tainted the kernel with `W`
but did not indicate an amdgpu/KFD fault, OOM, failed I/O or benchmark error;
the arm completed, memory stayed far above the guard, and the warning did not
recur in the longer 262K arm. It is retained in the complete bounded kernel
slice rather than hidden by an amdgpu-only filter.

The 262K arm then occupied 1,550.64 seconds wall time (951.29 seconds for pp and
597.64 seconds for tg). Peak RSS was 106,112,696 KiB and minimum
`MemAvailable` was 20,492,472 KiB (19.54 GiB), leaving **11.54 GiB above the
8 GiB guard**. VRAM/GTT sysfs peaks were 172,036,096/219,877,376 bytes. Only
10,496 KiB of swap-free was consumed and `pswpout` advanced 3,852 pages. The
bounded kernel slice had no GPU fault/reset, kernel OOM or new warning; stderr
had no error/failure/assertion, every sample completed, and the guard never
fired. Peak memory-pressure PSI `some/full avg10` was 31.60/31.53% (131K:
26.90/26.90%), so the run created real pressure despite retaining the required
operational reserve.

The direct answer is therefore **yes** for this benchmark mode: this exact 177B
IQ4_NL stack carries both 131,072 and the full native 262,144 context on
lordhenry while keeping more than 8 GiB available. Performance remaining at
those boundaries is the table above. In particular, full-boundary prefill is
stable but collapses to about 80.33 t/s for the final 16K chunk; decode remains
about 5.32 t/s. `llama-bench` still does not expose generated IDs, so this is
direct execution/stability and performance evidence, not an independent
semantic-output-quality test.

### MTP server arm

The pinned installer's exact Flash-Next defaults were then exercised on
`127.0.0.1:18014` only: 65536 context, 16384 batch/ubatch, one slot,
`draft-mtp`, the verified shared-Q8_0 sidecar on ROCm0, 99 draft layers and
`MTP_N_MAX=2`, with the same lazy-direct placement, gates and custom runtime.
Both target and draft loaded. One deterministic 128-token completion then
produced repeated malformed fragments, warnings about non-consecutive token
positions and an HTTP 500 when the content-only parser rejected the output.
The server reported 16.79 t/s and draft acceptance 0.01215 (3 accepted / 247
generated, mean length 1.02). The source publishes no Flash-Next MTP acceptance
reference, so no comparison is invented. This is a correctness/stability
failure, not a successful MTP reproduction, and the remaining two planned
requests were correctly skipped. Peak RSS was 88,310,344 KiB, minimum
`MemAvailable` 38,485,808 KiB, and its bounded kernel slice was also empty.

## First-boot gate

The independently supplied first-boot identity matched: `lordhenry`, boot ID
`07d2b2b3-4479-4675-826a-1bb24f45fd7b`. Relevant facts were:

* NixOS `25.11.20260318.fea3b36`, Linux `6.12.76`, firmware aggregate includes
  `linux-firmware-20260309-zstd`;
* `amdgpu.cwsr_enable=0`, MES=0, MES KIQ=0, GTT=114688 MiB, TTM page and pool
  limits both 29360128 pages;
* `/dev/kfd` and `renderD128` were mode 0666, group `render`; KFD/ROCm reported
  Radeon 8060S / gfx1151;
* physical split visible to the OS: 64 GiB VRAM, 62.44 GiB system RAM
  (`MemTotal=65,471,736 KiB`), and 112 GiB GTT aperture;
* initial free disk was 827,670,822,912 bytes before the model download,
  comfortably above the installer's 110 GiB safety request;
* no host `rocminfo` or `hipconfig` was installed. Inside the pinned image,
  HIP reported `7.15.26333-0000000`; the image is AMD's ROCm Core 10.0.0 image.

Before and after, the production qwen executable was the b10840 Nix store
binary with the original loopback listener, exact UD-Q3_K_XL shard, one slot,
131072 context and `ple_key|ple_value=CPU` placement. Both model timers, qwen
and Ollama were active after settlement; qwen `/health` and Ollama `/api/version`
returned HTTP 200; `systemctl --failed` was empty.

The hourly Ollama reconciliation happened to be running at the first stop. It
was terminated with Ollama, briefly appeared failed, and was reset after its
service was restored. Subsequent windows explicitly stopped/restored its timer
and completed with zero failed units.

## Build and provenance

Compilation had no GPU device passthrough. `test-backend-sched-ring` passed.
The candidate linked the custom HIP and ROCr prefixes ahead of ROCm 10's
hipBLAS, rocBLAS and LLVM libraries. `llvm-objdump --offloading` found 146
embedded HIP bundles and only the `gfx1151` device target.

| artifact | sha256 |
|---|---|
| `llama-server` | `ad2898b08356d3ee1b1fb18719e91f33f1fcf23185a5004c12ba08fed84de86d` |
| `llama-bench` | `2ce2668b48cea10a7e8cdeb6ff942f1481887e20292a895d81d834787624fcd2` |
| custom `libamdhip64.so.7` | `6ada53165e5afceb3efb7d822e3b901cb660172cb77f72be0ace02a7b5a8724c` |
| custom `libhsa-runtime64.so.1` | `1a6341b8f0116a5cacb24a3b8bf28591ad1da430730478844dd014cb73b97944` |

The source and OCI pins are immutable. Exact output hashes are still
window-specific because the published installer consumes unpinned Ubuntu build
packages and the server build fell back from its b10967 UI bundle to the
mutable `latest` UI bundle. This does not affect `llama-bench` kernels, but is a
reproducibility caveat for the server hash.

## Published model identity

The nine target shards total **100,043,569,504 bytes** (93.17 GiB), and the MTP
sidecar is **2,786,568,256 bytes** (2.60 GiB), for **102,830,137,760 bytes**.
Download took 896 seconds. Every installer-published SHA-256 matched:

```text
5b6032b1f3428a148a3b63d661a992dbe0e5f8e278ab684b3d2b474bc5372d30  00001
81ea612c230e5c3ee1e1036873b316bd6f3d0ba00aa9e12da9238b3ec75ef643  00002
d4c2432777ad3f2073989d9b584aaa69ea53201c22bfa69b0efc58fb3d4ffb9c  00003
72e276e9ffd33891b0640136b7f8c3ac765d34b3fae57d91cdbd4d25ce61477c  00004
c61c34d8c6e27051fb903f7117c6577cbd87b945e7fcdd3b7642a794dec78bac  00005
c9b36bca38ad5994c24a9d840460c7c3763cd64dfe2816effe1eabef5d7fc77a  00006
b18c40e93081df6b1001ed344af7de796f07a754f23001376cc9ed2d400effba  00007
3389e8907ce093d3ad45f5b46f14098d34352241cbc676361edbed7186ab023e  00008
8229be447e559c6f1186d8c878621afcf3466de71aca1b1c97e895288723b36e  00009
5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6  MTP
```

## First-boot load result and installer correction

No benchmark iteration ran on the first boot. There were two immediate,
bounded load attempts:

1. The published launcher exports `GGML_HIP_ENABLE_UNIFIED_MEMORY=1`, but this
   exact engine checks `GGML_CUDA_ENABLE_UNIFIED_MEMORY`. With the documented
   spelling, the loader used `cudaMalloc` and failed its 70,874,867,968-byte
   (67,591.54 MiB) ROCm0 buffer allocation.
2. Adding the engine-recognized spelling made it use managed memory. The kernel
   rejected the same allocation with
   `amdgpu: SVM mapping failed, exceeds resident system memory limit`.

Thus the exact stack could not load under that boot's 64 GiB VRAM / 64 GiB
system partition: the single 67,591.54 MiB resident weight buffer exceeded each
pool independently, despite the 112 GiB GTT aperture. Changing 24576 to 16384
batch could not reduce this model-weight allocation. This was a first-boot
firmware partition gate, not a terminal result; the resumed measurements above
supersede that disposition. There was no GPU reset, ring timeout, MES fault or
kernel OOM kill.

This also identifies a small upstream installer bug: set
`GGML_CUDA_ENABLE_UNIFIED_MEMORY`, not (or in addition to)
`GGML_HIP_ENABLE_UNIFIED_MEMORY`, for this engine revision.

## Residue and settlement

All residue is confined to the private benchmark directory
`/var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d`, mode 0700:

| component | allocated bytes |
|---|---:|
| verified model and MTP files | 102,830,211,072 |
| source, build and custom runtime | 2,312,458,240 |
| bounded Podman image/layer store | 20,916,899,840 |
| total experiment directory before resume | 126,062,903,296 |
| total experiment directory after resume | 126,063,230,976 |
| total experiment directory after native-context qualification | 126,063,497,216 |

The resume evidence/log delta was 327,680 allocated bytes. The native-context
harness and remote evidence added another 266,240 allocated bytes. Final free
space was 725,052,973,056 bytes. The directory remains the safe cleanup
boundary, but it was deliberately retained and the exact artifacts remain
useful for a later, separately authorized 500K/1M YaRN experiment. This native
result does not authorize or establish the memory safety of such an arm.

At settlement the exact production b10840
executable/argv was again listening on 127.0.0.1:8014, qwen, Ollama and its
dashboard plus both model timers were active, both health endpoints returned
HTTP 200, `systemctl --failed` was empty, port 18014 was closed, and the boot ID
was unchanged. The native arms likewise restored the exact executable/argv,
both correctly named model timers and all services after each bounded window;
the benchmark listener was closed and boot ID remained
`60093145-c25f-4f3f-b3af-cc931f6717f2`. No reboot, NixOS switch, deployment,
permanent unit/config change or public listener was made. The temporary root
authorization was not removed.

## Declarative follow-through

The later Fort candidate in `apps/qwen-flash-next` and
`pkgs/{pwilkin-rocm-strix,llama-cpp-pwilkin-strix}` packages these exact source
pins, nine hashes and qualified gates without depending on this retained
benchmark directory. It uses the full native context, 16384 batch/ubatch, one
slot, loopback-only service, an 8 GiB fail-safe and no MTP. Its activation note
makes semantic IQ4 quality and one real Pi tool-use run final production gates;
`llama-bench` execution evidence is not relabeled as semantic evidence.
