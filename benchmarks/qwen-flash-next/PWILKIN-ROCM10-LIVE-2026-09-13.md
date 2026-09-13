# pwilkin Strix Halo / ROCm 10 live qualification — lordhenry

Date: 2026-09-13 UTC. Plate: `545cf48d-88be-4419-9f99-14a602ebfce8`.

## Disposition

The recovered 1,086–1,204 prompt-token/s source is pwilkin's Strix Halo stack,
not EngramHalo.cpp. The exact source/runtime/weights were pinned, built and
verified, but **lordhenry cannot load the published model in its current memory
partition**, so no throughput number is claimed. Production was restored
without a reboot, deployment or persistent configuration change.

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

## Host gate

The independently supplied identity matched: `lordhenry`, boot ID
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

## Load result and installer correction

No benchmark iteration ran. There were two immediate, bounded load attempts:

1. The published launcher exports `GGML_HIP_ENABLE_UNIFIED_MEMORY=1`, but this
   exact engine checks `GGML_CUDA_ENABLE_UNIFIED_MEMORY`. With the documented
   spelling, the loader used `cudaMalloc` and failed its 70,874,867,968-byte
   (67,591.54 MiB) ROCm0 buffer allocation.
2. Adding the engine-recognized spelling made it use managed memory. The kernel
   rejected the same allocation with
   `amdgpu: SVM mapping failed, exceeds resident system memory limit`.

Thus the exact stack cannot load on this box's current 64 GiB VRAM / 64 GiB
system partition: the single 67,591.54 MiB resident weight buffer exceeds each
pool independently, despite the 112 GiB GTT aperture. Changing 24576 to 16384
batch cannot reduce this model-weight allocation, so the documented 16384
confirmation and MTP server arm were not attempted. There was no GPU reset,
ring timeout, MES fault, kernel OOM kill or reboot.

This also identifies a small upstream installer bug: set
`GGML_CUDA_ENABLE_UNIFIED_MEMORY`, not (or in addition to)
`GGML_HIP_ENABLE_UNIFIED_MEMORY`, for this engine revision.

## Residue and next safe action

All residue is confined to the private benchmark directory
`/var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d`, mode 0700:

| component | allocated bytes |
|---|---:|
| verified model and MTP files | 102,830,211,072 |
| source, build and custom runtime | 2,312,458,240 |
| bounded Podman image/layer store | 20,916,899,840 |
| total experiment directory | 126,062,903,296 |

Final free space was 724,649,144,320 bytes. Preserve this directory if a later
boot-time UMA partition experiment is approved; otherwise the whole directory
is the safe cleanup boundary. Do not delete individual production model files.
A credible next attempt requires changing the firmware/BIOS UMA carveout (or a
separately justified placement change), which requires a reboot and was outside
this authorization.
