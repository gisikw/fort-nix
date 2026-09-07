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

## Two live cache trajectories

**The constraint:** the Gated DeltaNet layers carry *recurrent* state.
llama.cpp's disk slot cache (`--slot-save-path`, `POST /slots/{id}?action=save`
and `…=restore`) does not preserve it. A restore therefore reinstates the
attention KV alongside stale/absent recurrent state — the server answers
happily and the trajectory is quietly wrong. That failure is silent, which is
the worst kind.

**The architecture that follows:**

* `--parallel 2` (asserted `>= 2`): one **resident** slot per trajectory. The
  slot *is* the trajectory; it is never evicted, never serialised, never
  reloaded.
* `--no-kv-unified`: separate KV per slot, so trajectory A's prefill cannot
  evict trajectory B's cache.
* `--ctx-checkpoints 8` + `--checkpoint-min-step 4096`: rewind points **inside
  the live context**. When the coordinator rewrites history (swapping a skill
  block out, see below), the server rolls back to the nearest checkpoint and
  re-runs only the tail instead of re-prefilling from token zero. Checkpoints
  are in-process state, not bytes on disk — that is exactly why they are legal
  here and slot save/restore is not.
* `--cache-ram 0` + `--no-cache-idle-slots`: nothing gets serialised behind our
  back. (The default 8 GiB RAM prompt cache would spill idle slots through the
  same state path.)
* `--no-context-shift`: with recurrent state, silently shifting positions
  corrupts a trajectory rather than truncating it. Fail loudly instead.
* No `--slot-save-path` is passed anywhere in this module. Do not add it.

Consequence to accept: **the trajectories do not survive a restart.** A server
restart (deploy, OOM, reboot) loses both. That is a correctness choice, not an
oversight — the alternative on this architecture is a restore that lies.

## Coordinator contract (future work, not implemented here)

`llama-server` does not understand rooms, sessions, personas or skills. It
understands slots and token prefixes. Everything below is the **coordinator's**
responsibility; this app only guarantees the substrate.

The intended shape, written down now so the substrate is not misread later:

1. **Active transcript (slot 0).** The live conversation, with skills injected
   into it as `<skill>…</skill>` blocks at the point of use.
2. **Shadow transcript (slot 1).** The same conversation with the *removed*
   injections replaced by the literal marker:

   ```
   <skill>This was loaded and has since been removed</skill>
   ```

   The shadow is prefilled **opportunistically** — the coordinator pushes it
   into slot 1 while slot 0 is idle, so that when the active transcript grows
   past the point where a skill must be dropped, the compacted continuation is
   already warm. Swap the roles of the slots, and the trajectory continues with
   no user-visible prefill stall.
3. **Slot affinity is explicit.** Pin each trajectory with `id_slot` on the
   **native** `POST /completion` endpoint — the OpenAI-compatible
   `/v1/chat/completions` path does **not** accept `id_slot`. A coordinator
   that speaks only OAI-compat gets round-robin slot assignment and both
   trajectories will trample each other.
4. **Prefix stability is the whole game.** The shadow transcript must be a
   *stable* prefix rewrite: change the marker text, the whitespace, or the
   ordering, and the reuse (`--cache-prompt` / `--cache-reuse 256`) collapses
   into a full re-prefill. The marker string above is therefore a wire
   constant, not a message to be edited freely.
5. **Never emulate rooms with slot save/restore.** If a third concurrent
   trajectory is needed, raise `slots` (and pay the KV) — do not spill one to
   disk. See the constraint at the top of this section.

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
