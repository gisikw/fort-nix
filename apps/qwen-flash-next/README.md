# qwen-flash-next — Qwen3.8-Flash-Next on Strix Halo

Serves **Qwen3.8-Flash-Next** (180B total / ~6B active) from lordhenry's
Ryzen AI Max+ APU (gfx1151, 128 GB unified memory) through a pinned Vulkan
build of llama.cpp.

Model shape (from the Qwen model card): 125B MoE body with 6B activated
(512 experts, 10 routed + 1 shared), **51B PLE n-gram embedding**, **4B MTP**
head, 48 layers laid out as `12 × (3 × (Gated DeltaNet → MoE) → 1 × (Qwen
Sparse Attention → MoE))`, 262144 native context.

## Source pinning

`pkgs/llama-cpp-halo` pins **ggml-org/llama.cpp `b10840`** (release of
2026-09-07) and builds it with `-DGGML_VULKAN=ON`.

* Upstream mainline already carries what this box needs: the `qwen4exp`
  architecture (`src/llama-arch.cpp`), the PLE tensor family
  (`blk.N.ple_key` / `ple_value` / …), server slots, and
  `--ctx-checkpoints` / `--checkpoint-min-step`.
* **EngramHalo.cpp is real and is the current performance reference.**
  [`Aristo94/EngramHalo.cpp`](https://github.com/Aristo94/EngramHalo.cpp), branch
  `strix-halo-qwen4exp`, contains the ROCm/gfx1151 sparse-QSA, MTP, and
  SSD-backed engram work measured by the abliter8 recipe. Its moving branch can
  be pinned (the published recipe used `4ff3affc2`), and it is the likely
  performance upgrade after a host-specific ROCm soak. The initial deployment
  deliberately uses a pinned upstream release instead: fewer patches and a
  backend already exercised on lordhenry are preferable while validating a new
  84 GiB model and its two-slot state semantics.
* **Vulkan first, not because ROCm is impossible.** lordhenry carries
  `amdgpu.cwsr_enable=0` as a workaround for the gfx1151 MES hang (ROCm #5590),
  and its existing accelerated services use Vulkan/RADV. EngramHalo's ROCm
  recipe uses compatible host tuning and may be faster; switching remains an
  explicit measured follow-up rather than an unsupported claim.

## Quant ladder and memory budget

128 GB unified memory, shared with the OS, ollama, and the GPU's own
allocations. Weights (exact bytes from the HF tree API, 2026-09-07):

| quant | shards | on disk | notes |
|---|---|---|---|
| `UD-Q4_K_XL` | 4 | 103.7 GiB | does not leave room for KV + ollama; not wired up |
| **`UD-Q3_K_XL`** | 3 | **83.8 GiB** | **default** |
| `UD-IQ3_XXS` | 3 | 76.3 GiB | fallback if GTT headroom proves tighter |
| `UD-Q2_K_XL` | 3 | 73.5 GiB | last resort; not wired up |

Two further levers:

* **GTT ceiling.** An APU can only map a fraction of system RAM into GTT by
  default (~50%), which is below the 83.8 GiB working set. The module sets
  `amdgpu.gttsize` / `ttm.pages_limit` / `ttm.page_pool_size` to 112 GiB
  (`tuneGtt = true`). **These are kernel parameters: they need a reboot.**
* **PLE on CPU.** `--override-tensor "ple_key|ple_value=CPU"` keeps the 51B
  n-gram lookup table mmap-backed in host memory instead of resident in GTT.
  It is a large, sparsely-touched table; the page cache handles it far better
  than the GPU allocator does. This is also the reason the initial Vulkan path
  does not bind the published single ~47.7 GiB PLE tensor as one Vulkan buffer
  (which exceeds the commonly reported 4 GiB binding limit). Actual model-load
  validation on lordhenry remains mandatory; if upstream still constructs a
  giant backend buffer before honoring the override, use EngramHalo's
  SSD-streamed path or split-PLE utility rather than weakening the memory gate.
  Set `ngramOverrideTensor = null` only after proving the resulting allocation.

## MTP speculative decoding: off, on purpose

unsloth publishes MTP draft heads (`shared-Q8_0`, 2.6 GiB, ~1.3–1.7× at
concurrency 1) — but their own README is explicit that **a stock
ggml-org/llama.cpp build cannot use them**: mainline has no MTP graph for
`qwen4exp` and no cross-model tensor borrowing.
[ggml-org/llama.cpp#28243](https://github.com/ggml-org/llama.cpp/pull/28243)
("models: Qwen3.8-Flash-Next MTP") was still **open** on 2026-09-07.

So `enableMtp = false` by default: enabling it on this pin would download
2.6 GiB that does nothing. To turn it on later, bump the `pkgs/llama-cpp-halo`
pin to a tag that contains #28243, then set `enableMtp = true` — the drafter
artifact, hash and flags (`--spec-draft-model … --spec-type draft-mtp
--spec-draft-n-max 2`) are already wired.

Note also unsloth's finding that MTP is a **net loss above ~concurrency 8**.
With two resident trajectories we are firmly in the regime where it helps.

## Provisioning

`qwen-flash-next-models.timer` (hourly, 5 min after boot) reconciles the model
store at `/var/lib/qwen-flash-next/models`:

1. **Capacity precheck.** Sums the bytes still missing, adds a 16 GiB margin,
   compares against `statfs` on the store. If it does not fit it logs
   `BLOCKED: need N GiB free … have M GiB. Not downloading.` and exits
   non-zero. **No ~90 GB download is ever started blind.**
2. Resumable `curl -C -` per shard, sha256-verified against the HF LFS oid,
   atomic rename into place.
3. On a complete store, `systemctl restart --no-block qwen-flash-next`.

`qwen-flash-next.service` has `wantedBy = [ ]` and a `ConditionPathExists` on
the first shard, so a host switch never starts a server whose weights are
absent — activation cannot be failed by this app.

## Context shape and hybrid-state persistence

Production uses `--parallel 1 --ctx-size 131072`: one 131072-token context.
The former setting was two separate 65536-token slots. Measurements and the
source audit that motivated the change are retained in
`benchmarks/qwen-flash-next/` and the operator report.

Qwen3.8-Flash-Next is not a KV-only transformer. Its hybrid memory consists of:

* sparse-attention K/V plus the QSA indexer cache;
* Gated DeltaNet recurrent **R** convolution and **S** matrix state for each
  recurrent layer; and
* a separate PLE convolution-history row.

A serializer that writes only attention KV cannot restore the trajectory. That
is an algorithmic constraint, not something more RAM can fix. However, the
pinned llama.cpp **b10840 does implement full sequence-state persistence**:
`llama_memory_hybrid_idx::state_write/read` chains the attention cache, the
recurrent cache, and the indexer cache; `llama_memory_recurrent::state_write`
explicitly writes R, S, and PLE rows. `llama_state_seq_save_file` and the
server's slot save action use that sequence-state path.

The distinction is therefore:

* KV-only restore: invalid for this architecture.
* Full hybrid-state serialization: architecturally possible and implemented by
  the pinned C API/server internals.
* Disk slot API in this deployment: **not exposed**, because no
  `--slot-save-path` is configured. The endpoint returns HTTP 501.
* RAM prompt cache: **disabled** with `--cache-ram 0` and
  `--no-cache-idle-slots`; if enabled, this build uses
  `llama_state_seq_get_data_ext(..., FLAGS_NONE)` and therefore includes full
  hybrid state.
* In-process context checkpoints: enabled (`8`, minimum spacing `4096`). They
  use `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY`; for hybrid memory that deliberately
  skips attention KV and captures recurrent state, while the resident KV prefix
  remains in place. They are rollback aids, not restart persistence.

The service still uses `--no-context-shift` and deliberately loses continuity
on restart. Those are conservative operational choices, not claims that this
version cannot serialize or shift recurrent state. Disk save/restore has not
been end-to-end qualified with this exact 90 GB GGUF, so enabling it should be
a separate correctness test despite the clear implementation path.

`llama-server` still has no concept of rooms or conversations. With more than
one slot, a coordinator must use `id_slot` on native `POST /completion`; the
OpenAI-compatible route does not provide the same explicit affinity contract.
Prefix stability remains necessary for resident prompt reuse.

## Endpoints

Bound to `127.0.0.1:8014`; the only ingress is this host's nginx entry,
declared through `fort.cluster.services` as VPN-only (no `visibility` key)
with token SSO and VPN bypass. Useful paths: `/health`, `/slots` (per-slot
occupancy — the coordinator's view of trajectory state), `/metrics`,
`/completion` (native, accepts `id_slot`), `/v1/chat/completions` (OAI-compat,
does not).

## Operating notes

* First start is slow: ~84 GiB has to come off disk into GTT.
  `TimeoutStartSec = 45min`.
* Check `journalctl -u qwen-flash-next-models` for `BLOCKED:` lines before
  assuming provisioning is stuck.
* Watch `n_ctx` in the startup log: `--ctx-size` is the **total**, divided
  across the slots.
