# EngramHalo / ROCm 10 qualification

> **Superseded execution target.** The source of the quoted 1,086–1,204
> prompt-token/s result was later recovered as pwilkin's different Strix Halo
> stack. EngramHalo remains useful negative/provenance evidence but was not
> built or run on lordhenry. See `PWILKIN-ROCM10-LIVE-2026-09-13.md`.

Audit date: 2026-09-13 UTC. Plate: `545cf48d-88be-4419-9f99-14a602ebfce8`.
This is source and toolchain qualification only. Nothing here is imported by
`apps/qwen-flash-next`, and no host was contacted or changed during this audit.

## Pins and provenance

| item | immutable pin | content identity / licence |
|---|---|---|
| EngramHalo.cpp | `15176583b358d791b7a73f210ef4ab9e167cfba7` (`strix-halo-qwen4exp` tip observed during this audit) | Nix unpack hash `sha256-vV6OYo8j6JeJn7c4ICCAmnDDkrqfhFv2F/4olW24k/g=`; MIT, upstream `LICENSE` sha256 `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` |
| llama.cpp architecture base | `6c84c7d5d8833c6e0df69628f75a0f599797934e` (merged PR #27742) | ggml-org/llama.cpp, MIT |
| abliter8 recipe | `abliter8-ai/qwen-3.8-next-flash-amd-strix-halo@0d31cd77c8cab5932088a8ed35de7e5bdd5801bc` | scripts/docs MIT; repository archive sha256 `ba5813c3e7b3c1d2fc50c3b8834e7f44754844af5b25c202cb8d9bd535b31a98` |
| ROCm 10 build environment | `docker.io/rocm/dev-ubuntu-24.04@sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374` | AMD-published image, created 2026-08-26, label version `10.0.0`, stable, package-installed from pinned TheRock scripts |
| TheRock release source | `ROCm/TheRock` tag `therock-10.0`, peeled commit `16adc4d875fd4f65ea23c7c84e1c66706fde3047` | component licences apply |

The fork has an empty `.gitmodules`; there are no submodules. Its two documented
optional container patches are already in the pinned source tree:

* `llama-cpp-25992-rocm-host-buffer.patch`, sha256
  `aca70db134d0e65be7a250cf1eb4237bb739d9d586f5c5153ce972372f67b4de`
  (multi-slot iGPU correctness workaround). It is irrelevant to the proposed
  one-slot test and is **not** applied by our candidate.
* `llama-cpp-qwen38-per-buffer-mmap.patch`, sha256
  `971d428de98ecdf59941946bb391c257e82501ce98b7c71cc1f34803181fe133`
  (loader experiment). It is likewise not applied. The fork's Dockerfile only
  applies it when it still fits and otherwise skips it, which is not an
  acceptable reproducibility rule for this candidate.

The Qwen weights are separately licensed under Qwen Community License 1.0.
That licence, including Model-as-a-Service restrictions, is not replaced by the
engine's MIT licence. The existing Unsloth GGUF shard hashes remain the model
identity for stage 1.

### Revision discrepancy resolved

`4ff3affc2ac5861f7dda42bcf5ff653c776b816f` is the exact old branch revision
pinned by abliter8's sole recipe commit and used for its published runs. It is
`b10653-68-g4ff3affc2` and is now retained only on the fork's
`archive/2026-08-28-pre-master-rebase` branch. `60bce1a304394203e4e4285cf795138026d9f793`
is a later rebase/documentation snapshot tagged `strix-halo-qwen4exp-b10807-60bce1a`
(and `archive/2026-09-08`), not the abliter8 measurement revision. The live
branch has since rebased again and is now `15176583...` (`b10659-296`). Thus old
short SHAs do not name equivalent trees even where their final documentation
commit message is the same. New work pins the full current SHA and Nix hash.

The live fork also has immutable rolling tags through
`strix-halo-qwen4exp-b10909-cdc23f7`; we chose the newer audited full SHA rather
than pretending a moving branch name is a pin.

## What the sources actually claim

The current EngramHalo guide is a **ROCm/HIP-only** guide tested with the
TheRock **7.14** container. Its generic `.devops/rocm.Dockerfile` defaults to
ROCm **7.2.1**. The abliter8 `build-engine.sh` says “ROCm (7.x)” and pins
`4ff3affc2`. Neither source prescribes ROCm 10, retained PM4, or reports
1,086–1,204 prompt tok/s.

The current fork reports at most about 468–502 tok/s for comparable `pp4096`
at depth zero (IQ3_XXS/IQ4_XS depending on cache state), and about 192–216
tok/s averaged over a 156K prompt. Abliter8 reports roughly 290 tok/s in its
0–48K sweep and 87 tok/s at a separately measured 201K reference point. Its
headline 55–82 tok/s values are **decode with MTP**, not prefill. Therefore the
previously quoted 1,086–1,204 prefill range has no provenance in the live fork,
its docs, its benchmark file, the article, or the abliter8 repository. It must
be treated as an unverified result from some other stack until a URL, revision,
quant and command are supplied.

This matters: the published EngramHalo numbers used UD-IQ3_XXS or UD-IQ4_XS,
q8_0 KV, `-b 8192 -ub 2048`, and either a page-cached/resident or SSD-lazy
engram. They are not an apples-to-apples comparison to Lordhenry's exact
UD-Q3_K_XL, default 2048/512 Vulkan result.

## Fork feature isolation

The branch includes 295 commits beyond the old qwen4exp merge base because it
tracks/rebases upstream. A whole-tree diff against that old base therefore
mislabels hundreds of later upstream fixes as EngramHalo work. The authored
patch series and current disposition are the useful isolation:

| feature | patch / current path | phase | include first? |
|---|---|---|---|
| Qwen4Exp architecture, QSA and DeltaNet graph | upstream PR #27742 base plus later upstream fixes | common architecture | yes, required |
| masked FA slice early-exit and head-256 RDNA selection | `c97d5b7f8...` | prompt and decode HIP kernel selection | yes |
| chunked Gated DeltaNet | `3cf7cb50a...`, `GGML_HIP_GDN_CHUNK=1` | specialized prefill | separate one-variable arm; it was opt-in and absent from the fork's published numbers |
| long-row QSA top-k | original fork patch `33766da9...`; current tree uses upstream radix TOP_K `f8dbcd618` (#27466) | long-context decode/indexer | present, not a prefill attribution |
| true QSA selected-row gather | `92454d1b7...`, default threshold 16K; `LLAMA_QSA_GATHER=0` disables | primarily long-context decode | disable for first prefill arms |
| SSD/lazy engram and non-QK_K IQ4_NL get-rows | `8eb931ba3...` | model loading/residency and random gathers | use only if required to fit; label `ssd-lazy` |
| load-time mmap drop-behind | `d87bc9e25...`, default enabled | load transient only | keep; not a throughput claim |
| MTP sidecar/graph and converter | `5ae04cb02...`, `c6c726bda...` | speculative decode | disable first |
| multi-slot host-buffer workaround | external documented patch #25992 | correctness/container glue | omit at parallel=1 |
| retained PM4 | no implementation, option, environment variable, commit or documentation in this fork | absent | excluded |
| container glue | `docs/strix-halo/Dockerfile.rocm-7.14`, generic `.devops/rocm.Dockerfile` | packaging | not part of kernel A/B |

The smallest honest prefill sequence is therefore the same pinned HIP binary in
both arms, one slot, no draft model, `LLAMA_QSA_GATHER=0`, first
`GGML_HIP_GDN_CHUNK=0`, then `=1`. This isolates the specialized GDN kernel.
The full Vulkan-versus-HIP result still attributes a backend plus fork, not one
kernel; the within-HIP arm supplies the kernel attribution.

## What “ROCm 10” means here

ROCm 10.0.0 is real and obtainable, not a name for 7.14. AMD's release notes
name ROCm Core SDK 10.0.0, HIP 10.0, and gfx1151/Strix Halo in the hardware and
profiler support tables. AMD publishes the immutable 8.05 GB-layer development
image pinned above. The corresponding TheRock source release is pinned above.
The compilation contract is:

```text
ROCM_PATH=/opt/rocm HIP_PATH=/opt/rocm
CMAKE_HIP_COMPILER=$(hipconfig -l)/clang
CMAKE_HIP_ARCHITECTURES=gfx1151
AMDGPU_TARGETS=gfx1151 GPU_TARGETS=gfx1151
GGML_HIP=ON GGML_VULKAN=OFF GGML_CUDA=OFF
GGML_HIP_FORCE_MMQ=ON GGML_HIP_ROCWMMA_FATTN=OFF
```

`HSA_OVERRIDE_GFX_VERSION=11.5.1` should not be needed when the runtime and
libraries natively carry gfx1151; record an initial failure before considering
it. `ROCBLAS_USE_HIPBLASLT` is another variable and stays fixed within every
A/B.

Fort's locked nixpkgs is commit
`bd3bac8bfb542dbde7ffffb6987a1a1f9d41699f` (2025-03-26) and exposes ROCm
**6.4.3**, although it has a `gfx1151` package scope. It cannot build this
qualification and is not silently used. No audited nixpkgs revision in this
worktree provides ROCm 10. `pkgs/llama-cpp-engramhalo/default.nix` therefore
asserts that `rocmPackages.clr` has major version 10 and documents the future
overlay interface. `build-engramhalo-rocm10.sh` is the immediately reproducible
candidate route and pins AMD's image by manifest digest, not a tag.

User-space qualification does not qualify the host. A run still requires:

* `/dev/kfd` and the render node, matching `video`/`render` access;
* an amdgpu kernel and firmware that recognize gfx1151 and interoperate with
  ROCm 10's userspace ABI;
* the existing unified-memory GTT/TTM limits (Lordhenry's 112 GiB policy) and
  enough physical headroom for GTT plus CPU processes and page cache;
* explicit recording of kernel, firmware package, amdgpu parameters, MES mode,
  `rocminfo`, `hipconfig --full`, and installed rocBLAS code objects;
* the existing `amdgpu.cwsr_enable=0` workaround must be recorded, not assumed
  to solve a ROCm 10 issue. Any change to it is a separate reboot experiment.

Azula exposes `/dev/kfd` and a render node but has neither Podman/Docker nor the
pinned 8+ GB ROCm 10 closure. Its flake has ROCm 6.4.3. Consequently this audit
can prove source fetching, Nix evaluation, static checks and the AMD image
digest, but cannot honestly claim a ROCm 10 compile or gfx1151 execution.

## Model compatibility and two-stage experiment

The pin contains qwen4exp loading and generic GGML K-quant kernels; there is no
loader whitelist rejecting `UD-Q3_K_XL`. The exact three-shard GGUF should load
by architecture/type, but that remains a hypothesis until the 89,975,329,280
bytes are loaded by this exact binary. The published SSD helper specifically
adds an odd-row IQ4_NL get-rows path; that does not prove every Q3_K_XL engram
placement is accelerated. A load-only check is therefore the first host gate.
Do not relabel “source appears compatible” as “loads.”

1. **Architecture A/B:** exact existing UD-Q3_K_XL shards and hashes, exact
   committed corpus, the production/default KV type and 2048/512 batch shape,
   no MTP, no retained PM4, one slot. First preserve the production
   `ple_key|ple_value=CPU` override. Use `-lm mmap --lazy-mode on` only if that
   placement cannot run under HIP and label the changed arm `ssd-lazy`; use
   q8_0 KV only as another separately labelled fallback. Compare stock Vulkan,
   HIP/GDN-off, and HIP/GDN-on at 30K (plus 4K as a diagnostic).
2. **Published-stack ceiling:** only after stage 1, fetch and hash the exact
   UD-IQ3_XXS and/or UD-IQ4_XS used by the publication, use its 8192/2048 batch,
   q8_0 KV and stated engram/cache state. Reproduce no-MTP prefill first; add
   MTP only for a separately labelled decode experiment. This is intentionally
   non-apples-to-apples against production UD-Q3_K_XL.

For each retained arm: one discarded warmup and at least three retained
replays of every distinct 30K corpus case; native server prompt/decode timings;
peak amdgpu VRAM/GTT, `MemAvailable`, process RSS/anon; before/after boot ID and
kernel journal slices covering amdgpu, MES, ring timeout, reset, XNACK and OOM.
The harness now preserves sampled output token IDs and `compare` fails if IDs
are absent or differ. Text equality alone is not called token identity.

The first HIP process should be the production command shape below on a spare
loopback port. Change only `GGML_HIP_GDN_CHUNK` between the two HIP arms. If a
flag was renamed at the current fork pin, record `--help` and make the minimal
semantic translation rather than silently dropping it.

```bash
env GGML_HIP_GDN_CHUNK=0 LLAMA_QSA_GATHER=0 ROCBLAS_USE_HIPBLASLT=0 \
  ./build-rocm10/bin/llama-server \
  --host 127.0.0.1 --port 18014 \
  --model /var/lib/qwen-flash-next/models/Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf \
  --alias Qwen3.8-Flash-Next --jinja --gpu-layers 999 --flash-attn auto \
  --parallel 1 --no-kv-unified --ctx-size 131072 \
  --cache-prompt --cache-reuse 256 --cache-ram 0 --no-cache-idle-slots \
  --no-context-shift --metrics --override-tensor 'ple_key|ple_value=CPU'
# Arm 2: identical, except GGML_HIP_GDN_CHUNK=1.
# Deliberately absent: -md, --spec-*, retained-PM4 flags, large batch flags.
```

Use the existing direct Vulkan command from `BATCH-MATRIX-2026-09-13.md` for
the baseline; do not rely on a request sent through the production listener.

## Minimal next authorization

Authorize one temporary, non-deploying Lordhenry shell session with permission
to use `/dev/kfd`/render and to stop/restart competing GPU services during a
bounded window. Do not authorize a push, NixOS switch, service edit, reboot, or
network listener. In that session:

1. record the host facts above and verify all model shard hashes;
2. run the pinned ROCm 10 build recipe in its private work directory and inspect
   `hipconfig`, linked libraries and embedded gfx1151 code objects;
3. execute `llama-server` directly on a new loopback-only port, first load-only,
   then the two no-MTP/no-QSA-gather GDN arms; do not pass `-md` or any spec flag;
4. replay the immutable corpus with, for example,
   `candidate_benchmark.py llama --warmups 1 --replays 3 --configuration ...`;
5. restore stopped services and prove their original executable/arguments,
   timer state and health, even if loading or benchmarking fails.

Stop immediately on model rejection, OOM kill, GPU reset, MES/ring fault,
wrong device/code object, or missing output token IDs. This is the smallest
safe access that can cross the current honest boundary.
