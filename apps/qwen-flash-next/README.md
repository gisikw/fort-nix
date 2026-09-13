# qwen-flash-next — qualified 177B IQ4_NL candidate on lordhenry

This app is the declarative production candidate for the exact successfully
qualified stack in
[`benchmarks/qwen-flash-next/PWILKIN-ROCM10-LIVE-2026-09-13.md`](../../benchmarks/qwen-flash-next/PWILKIN-ROCM10-LIVE-2026-09-13.md):

* model `ilintar/qwen3.8-flash-next-gguf-strix-halo`, exact nine-shard
  `Qwen3.8-Flash-Next-IQ4_NL-PROJFIX` (100,043,569,504 bytes / 93.17 GiB);
* custom ROCr/HIP `pwilkin/rocm-systems@7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1`;
* engine `pwilkin/llama.cpp@f5daaa3cfa6358e5dd398911ec741813745a5440`;
* ROCm0, all layers offloaded, flash attention on, F16 K/V, `--load-mode none`,
  lazy `on-direct`, batch and ubatch 16384, one slot, no context shift;
* a hard 262,144-token native context; and
* **no MTP sidecar and no speculative decoding**. The qualified MTP arm had
  1.215% acceptance, malformed output, and HTTP 500.

The packages under `pkgs/pwilkin-rocm-strix` and
`pkgs/llama-cpp-pwilkin-strix` use fixed source hashes and ordinary sandboxed
Nix builds. Production has no dependency on the retained benchmark directory,
a container, mutable Ubuntu packages, or benchmark-built binaries. The engine
build disables its web UI, avoiding the upstream mutable UI-bundle fallback.
Only gfx1151 HIP code is requested for llama.cpp. The service puts custom HIP
and ROCr ahead of the pinned Nix ROCm SDK libraries in `LD_LIBRARY_PATH`.

Fort's pinned SDK is ROCm 6.4.3/LLVM 19, while this future custom runtime source
identifies itself as HIP 7.16 and was qualified when built in AMD's ROCm 10
image. The Nix package therefore carries explicit, reviewed compatibility
patches limited away from lordhenry's native execution path: it omits future
gfx12/gfx12.5 embedded runtime shaders, disables HIPRTC PCH generation,
provides COMGR 3.0 fallbacks for SPIR-V-only actions, and leaves the gfx11
runtime entries and native gfx1151 llama bundles unchanged. llama.cpp does not
use HIPRTC or SPIR-V in this deployment. This is a reproducible source/behavior
pin, not a claim that different toolchains emit byte-identical ELF files.

The built candidate hashes are:

| artifact | Nix candidate SHA-256 | qualification-window SHA-256 |
|---|---|---|
| `llama-server` | `f93439ab77b89de329a6a07d881c8c4071d20ce19cdb49357b310eb2351b53a4` | `ad2898b08356d3ee1b1fb18719e91f33f1fcf23185a5004c12ba08fed84de86d` |
| `llama-bench` | `70f719b5d8303308d7c0bef0d8391419590083c796a6e5c1cbf6f6879f00fe0b` | `2ce2668b48cea10a7e8cdeb6ff942f1481887e20292a895d81d834787624fcd2` |
| custom `libamdhip64.so.7` | `8b8d25a008efb0a4b5657edcc4de6a4c0a253fb62c258bc2ba0bd66cca575ba4` | `6ada53165e5afceb3efb7d822e3b901cb660172cb77f72be0ace02a7b5a8724c` |
| custom `libhsa-runtime64.so.1` | `5527accb7fcf0e94ba6fa5bcc9c641922d10d5d603a302f4b80d194943807170` | `1a6341b8f0116a5cacb24a3b8bf28591ad1da430730478844dd014cb73b97944` |

That expected ELF difference is why activation requires the Nix closure's own
semantic/tool-use proof before dispatch; retained benchmark binaries are
provenance, never a runtime fallback.

The runtime exports both unified-memory spellings. This exact engine checks
`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`; the HIP-named variable by itself is
ineffective. All other qualified launcher gates are explicit in the unit.

## Architecture choice: replacement, with disk rollback

This candidate **replaces the process behind existing private port 8014** and
keeps Fort service name `qwen-next`. It does not declare a second endpoint:
lordhenry has disk for both artifact sets, but cannot safely keep both
~100-GiB-class processes resident. A second auto-startable unit would turn an
apparently additive change into an OOM hazard. Loopback remains the only server
listener; existing Fort VPN/token nginx ingress is unchanged, with no firewall
opening or new public listener.

Rollback is intentionally disk-cheap rather than resident-additive. The old
three-shard `UD-Q3_K_XL` files are preserved. Reverting the candidate commit
restores the b10840/Vulkan Q3 service declaration on the same endpoint. Do not
remove either model set until the new stack passes activation.

`restartIfChanged = false` means a NixOS activation does not interrupt the
currently running Q3 process merely because its unit changed. The model timer
stages and verifies the candidate, then deliberately restarts the one service
after the complete nine-file set is committed. That is the production cutover.

## Model reconciliation

`qwen-flash-next-models` is the established reconciler, now locked to all nine
IQ4_NL shards. It:

1. computes remaining bytes and refuses to fetch without those bytes plus a
   16 GiB disk margin;
2. resumes one `.downloading` staging file at a time with bounded curl retries,
   exact length and SHA-256 checks, and same-filesystem atomic rename;
3. creates a manifest-specific completion marker only after every shard is
   verified; the server requires this marker and therefore never loads a
   partial set; and
4. restarts only after an artifact changed, or starts an inactive service once
   reconciliation is complete.

A matching completion marker takes the daily timer's fast path: all lengths are
rechecked, but 93 GiB is not redundantly streamed into page cache every day.
Deleting the marker requests a full cryptographic revalidation without a model
download. Builds/evaluation/tests never fetch GGUF data.

Expected one-time disk delta is exactly 100,043,569,504 bytes of file content
(93.17 GiB), plus filesystem metadata and any resumable staging file. During a
single shard's atomic handoff, there is no second completed copy. The existing
Q3 model and the retained ~126 GB benchmark directory remain separate cleanup
boundaries.

## Memory and firmware gates

The qualification succeeded on Linux 6.12; no kernel upgrade prerequisite is
claimed or encoded. BIOS UMA **must be exactly 2 GiB**. Firmware remains an
external host prerequisite, not something Fort attempts to manage. `ExecStartPre`
checks the visible 2 GiB VRAM carveout, approximately 128 GiB system memory,
the complete model marker, and at least 8 GiB `MemAvailable`.

A parent watchdog samples Linux `MemAvailable`. If it remains below 8 GiB for
15 seconds, it terminates only its llama-server child and exits failed so the
bounded restart policy applies. This is a fail-safe, not a claim that Linux
reserves 8 GiB. `MemorySwapMax=0` prevents the inference service from relying
on swap; no swap configuration is added. The unit is deliberately preferred
over unrelated services under an actual OOM (`OOMScoreAdjust=500`) and never
kills unrelated processes.

At the full 262,144-token qualification boundary, minimum `MemAvailable` was
19.54 GiB: 11.54 GiB above the guard. There was no OOM, reset, or swap
pathology. Allocation is llama.cpp's incremental/lazy-direct path rather than a
vLLM-style maximum-context weight pre-reservation; the hard context is still
262,144.

## Readiness and measured behavior

Process existence is not readiness. The service remains `activating` while an
`ExecStartPost` probe waits up to 45 minutes for both HTTP 200 from `/health`
and the exact alias in `/v1/models`. Overall startup timeout is 50 minutes.
Failure is bounded to three starts/hour with a 60-second delay. The reconciler
cannot start it without the set-level marker.

Qualified independent `llama-bench` pp/tg results (tg does **not** continue the
pp test):

| test | result |
|---|---:|
| depth 0, pp16384 | 1065.76 ± 5.97 t/s |
| depth 0, tg128 | 27.97 ± 0.13 t/s |
| depth 40,000, pp16384 | 1019.24 ± 5.59 t/s |
| depth 40,000, tg128 | 18.00 ± 0.08 t/s |
| pp16384 at d114688, ending 131,072 | 867.15 ± 4.15 t/s |
| tg128 at d130944, ending 131,072 | 9.664 ± 0.022 t/s |
| pp16384 at d245760, ending 262,144 | 80.330 ± 0.048 t/s |
| tg128 at d262016, ending 262,144 | 5.315 ± 0.013 t/s |

For agent work, compact around **64–96K** in normal operation and treat 262K as
emergency runway. This is operational advice, not a false hard-context value in
the Tiamat catalog.

## Tiamat model/profile

Lordhenry's existing tiamat-router bootstrap gains one static local provider:

* provider: `llama-lordhenry-qwen38-flash-next-iq4nl`
* model: `Qwen3.8-Flash-Next-IQ4_NL-PROJFIX`
* agent-dispatch profile ID:
  `tiamat-openai-llama-lordhenry-qwen38-flash-next-iq4nl/Qwen3.8-Flash-Next-IQ4_NL-PROJFIX`

Tiamat Router's generic local-provider catalog does not have a separate policy
profile object: the concrete provider/model pair above is the dispatch profile.
A duplicate legacy-Tiamat profile is intentionally not added because it would
bypass Router readiness/availability and broaden a different authorization
surface.

It advertises OpenAI completions, text input, reasoning, 262,144 context, a
conservative 32,768-token output ceiling, and zero monetary token cost. Total
prompt plus output must remain within context. It does not advertise vision or
MTP.
OpenAI-compatible tool calls are passed through, but semantic/tool behavior is
an activation gate below. The provider uses `127.0.0.1:8014`; no public model
listener is needed.

The bootstrap client list is unchanged. A declarative Router CRUD reconciler
creates/updates the provider as `unavailable/upstream` unless `/v1/models`
contains the exact IQ4 alias. A dependent oneshot publishes `available` only
after the llama service's full readiness probe; stopping that service marks it
unavailable again. This prevents the still-running rollback Q3 model during
staging from answering a request labeled as IQ4. Credentials are passed to curl
through a mode-0600 temporary config, not argv or the Nix store.

This does not enroll the model into broader Native Agents or add it to azula
Golem's harness allowlist. Operators can authorize that separately after
quality gates pass.

## Activation gate and rollback runbook

Do not delete the retained benchmark directory during this procedure.

1. Build and activate the reviewed Fort generation. Activation itself leaves
   the running Q3 process alone (`restartIfChanged = false`). Confirm BIOS UMA
   is still 2 GiB and preserve at least roughly 110 GiB free (93.17 GiB model +
   16 GiB reconciliation margin + metadata).
2. Start `qwen-flash-next-models.service` intentionally, or wait for its timer.
   Follow `journalctl -fu qwen-flash-next-models`. The qualified live download
   took about 896 seconds, but network and disk conditions may make it longer.
3. Expect one service interruption when the set completes. Loading is large and
   may take tens of minutes. Follow `journalctl -fu qwen-flash-next` and require:

   ```sh
   systemctl is-active qwen-flash-next.service
   curl -fsS http://127.0.0.1:8014/health
   curl -fsS http://127.0.0.1:8014/v1/models \
     | jq -e '.data[] | select(.id == "Qwen3.8-Flash-Next-IQ4_NL-PROJFIX")'
   ss -ltnp | grep '127.0.0.1:8014'
   systemctl --failed
   ```

4. Inspect argv/environment and prove ROCm0, full offload, flash attention,
   F16 K/V, load-mode none, lazy on-direct, 16K batch/ubatch, one slot, 262K,
   no context shift, custom library precedence, and both unified-memory names.
   Re-hash all nine independently provisioned shards once.
5. **Before production dispatch**, run a deterministic semantic-quality smoke
   check of this IQ4 quant, then one real Pi agent task that must make and
   consume a tool call. Reject activation for malformed/repeated output or
   tool-call failure. Do not enable MTP as a remedy.
6. Exercise dispatch through the provider/model ID above and confirm
   tiamat-router's catalog reports the exact metadata.

To roll back, revert the candidate commit and activate that generation. The old
Q3 files were not removed, so `qwen-flash-next-models.service` can validate and
restart the prior b10840/Vulkan endpoint. Verify its old alias and health.
Only after the Nix-built runtime, independent model store, semantic smoke, Pi
tool run, and router dispatch all pass may an owner separately authorize:

```text
rm -rf /var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d
```

That retained directory is approximately 126 GB and is the sole benchmark
cleanup boundary. It is not removed by this candidate.
