# qwen-flash-next on lordhenry

This app declares the dedicated experimental Qwen3.8-Flash-Next service on
lordhenry. It reproduces the bounded performance evidence recorded in
[`benchmarks/qwen-flash-next/PWILKIN-ROCM10-LIVE-2026-09-13.md`](../../benchmarks/qwen-flash-next/PWILKIN-ROCM10-LIVE-2026-09-13.md);
it does **not** claim semantic or tool-use qualification.

## Exact stack

- model repository: `ilintar/qwen3.8-flash-next-gguf-strix-halo`
- model alias: `Qwen3.8-Flash-Next-IQ4_NL-PROJFIX`
- nine declared shards, 100,043,569,504 bytes (93.17 GiB), each pinned by
  filename, byte length, and SHA-256
- runtime: `pwilkin/rocm-systems@7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1`
- engine: `pwilkin/llama.cpp@f5daaa3cfa6358e5dd398911ec741813745a5440`
- loopback `127.0.0.1:8014`, ROCm0, all layers offloaded, flash attention on
- hard context 262,144; batch and ubatch 16,384; one slot; no context shift
- F16 K/V, `--load-mode none`, lazy `on-direct`, unified memory
- no MTP sidecar and no speculative decoding

The Nix packages are fixed-output, sandboxed builds independent of benchmark
binaries and mutable container packages. The retained benchmark directory is
evidence and an optional one-time source for byte-identical shard seeding; it
is never a runtime dependency. Do not alter or delete it as part of deployment.

## Lifecycle

There are no activation, dispatch-approval, or lifecycle-identity markers and
no manual approval services. The only marker is the manifest-specific artifact
completion marker:

```text
/var/lib/qwen-flash-next/models/.Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-2f152a082cdff9959d5a.complete
```

`qwen-flash-next-models.service` reconciles the complete nine-shard set. A
missing shard is downloaded to a same-filesystem `.downloading` path with
bounded retries, then checked for exact length and SHA-256 and atomically
renamed. The completion marker is atomically written only after the complete
set verifies. A valid marker takes a length-check fast path on later runs;
delete only this completion marker to request a full re-hash.

The reconciler runs at boot and daily. On success it starts
`qwen-flash-next.service`. The server is also enabled normally at boot and its
preflight refuses to start unless the exact completion marker exists, UMA is
exactly 2 GiB, the host has approximately 128 GiB RAM, and `MemAvailable` is at
least 8 GiB. Thus an incomplete box stages artifacts without exposing a partial
model, while a complete box boots directly into service.

This service replaces the prior Q3 process on port 8014. The previous Q3 shards
remain a rollback boundary; the two ~100-GiB-class models must not run
concurrently. Lordhenry's Ollama app is also deliberately disabled while this
candidate is resident: its infinite-keepalive runners retained about 42 GiB
and made the 8 GiB safety posture impossible. This leaves the old ratched
Ollama scoring route unavailable during the experiment rather than risking a
host OOM.

## Safe local shard seeding

For this deployment, prefer the already-verified files under
`/var/lib/qwen-flash-next/benchmarks/strix-halo-rocm10-545cf48d`. Never trust
filenames alone.

1. On lordhenry, compare every source file's byte length and SHA-256 with the
   declaration in `default.nix`. Abort on any mismatch or missing shard.
2. Stage each verified source as the expected destination filename plus a
   temporary suffix inside `/var/lib/qwen-flash-next/models`.
3. Prefer a reflink copy (`cp --reflink=always`) when supported. Otherwise use
   a normal copy. Do not use a symlink. Use a hardlink only after proving that
   ownership, mutation, filesystem, and retention semantics cannot couple the
   benchmark and declarative trees; an independent copy is safer.
4. Set owner/group to `qwen-flash-next:qwen-flash-next` and non-writable model
   modes, re-check destination length and SHA-256, then rename each file
   atomically to its declared filename.
5. Do not manufacture the completion marker. Start
   `qwen-flash-next-models.service`; it verifies the set and commits the marker
   without network transfer.

Once copied/reflinked, the declarative model tree has no path dependency on the
benchmark directory.

## Memory, firmware, and readiness

The service requires the current qualified 2 GiB UMA boot
(`mem_info_vram_total == 2147483648`); Fort does not manage firmware. It sets
2 GiB UMA/GTT posture through the declared kernel parameters and exports both
unified-memory spellings, including the engine-required
`GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`.

A parent watchdog samples `MemAvailable` every five seconds. If it remains
below 8 GiB for 15 seconds, it terminates only llama-server and lets the bounded
restart policy apply. `MemorySwapMax=0`, `OOMPolicy=stop`, and
`OOMScoreAdjust=500` protect the rest of the host but are not a reservation.

Readiness requires both `/health` and the exact alias in `/v1/models`, with
bounded two-second probes and a 45-minute overall deadline inside the 50-minute
systemd start timeout. Starts are limited to three per hour.

## Tiamat publication and selection policy

Tiamat Router declares one local provider:

- provider `llama-lordhenry-qwen38-flash-next-iq4nl`
- model `Qwen3.8-Flash-Next-IQ4_NL-PROJFIX`
- upstream `http://127.0.0.1:8014/v1`, Router-verified locality `local`
- OpenAI completions, text/reasoning, 262,144 context, 32,768 max output

Publication follows exact model identity and liveness. The provider starts
`unavailable/upstream` and becomes available only when `/health`
succeeds and `/v1/models` contains the exact alias; stopping the model
unpublishes it.

**Available and discoverable does not mean selected.** This change adds no
Golem/Familiar profile, allowlist entry, launch workload, or default model
selection. Semantic and tool-use qualification is required before anyone
deliberately selects this provider for agent work, not before the service is
made available for testing.

## Deployment and verification

Use the repository's tracked GitOps path: validate and push the reviewed linear
history to `main`, then use `just deploy lordhenry` to wait for/confirm the
lordhenry switch. Do not deploy another host. No reboot is needed while the
current boot reports exact 2 GiB UMA.

After switching, monitor:

```sh
sudo systemctl status qwen-flash-next-models.service qwen-flash-next.service
sudo journalctl -fu qwen-flash-next.service
curl -fsS http://127.0.0.1:8014/health
curl -fsS http://127.0.0.1:8014/v1/models | jq .
ss -ltnp | grep -F '127.0.0.1:8014'
```

Verify the Nix-store `ExecStart`, process argv/environment, executable and
closure, all nine hashes and lengths, completion marker content, Tiamat catalog
route/locality, current UMA/boot, memory margin, and zero failed units. Run only
bounded direct loopback semantic and forced tool-schema smoke. Do not launch a
Golem/Familiar agent workload and do not change defaults. A failed semantic
smoke leaves the service available for diagnosis but not selected.

## NixOS generation rollback

Record the pre-deployment generation from:

```sh
sudo nix-env --list-generations -p /nix/var/nix/profiles/system
readlink -f /nix/var/nix/profiles/system
```

If switching, model loading, or readiness fails, use the prior generation's
tracked switch script rather than editing live units:

```sh
sudo /nix/var/nix/profiles/system-<PREVIOUS>-link/bin/switch-to-configuration switch
sudo systemctl restart qwen-flash-next.service
```

Verify the restored Q3 alias and health on port 8014 and the restored Ollama
endpoint if rolling back the whole experiment. A reboot is not normally
required; do not change firmware. Preserve the previous generation, old Q3
shards, retained benchmark directory, and authorized recovery SSH key until
rollback risk is explicitly closed.
