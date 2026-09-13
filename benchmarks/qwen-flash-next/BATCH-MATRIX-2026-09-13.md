# Qwen Flash-Next batch/ubatch matrix — lordhenry, 2026-09-13

## Scope and controls

This was the first bounded larger-batch pass. It used only the production
Vulkan llama.cpp package and the committed fixed corpus; no package was built,
deployed, or changed, and no ROCm/PM4/halo-box work was started.

* Host/boot: `lordhenry`, boot ID
  `07d2b2b3-4479-4675-826a-1bb24f45fd7b`.
* Binary: `/nix/store/kkm2623mp3788y3a1l5db4qh71hvq402-llama-cpp-halo-10840/bin/llama-server`;
  sha256 `9dbed68c344afce8ea0759cce788ff081e85895e006190fc9aa6ad521ab4cabf`.
  `--version` reports `0.4.0-dev (build 0, commit unknown)`; the Nix derivation
  is the repository's `ggml-org/llama.cpp` release pin **b10840**.
* Model: Unsloth Qwen3.8-Flash-Next `UD-Q3_K_XL`, three GGUF shards totaling
  89,975,329,280 bytes. The first shard was
  `/var/lib/qwen-flash-next/models/Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf`,
  sha256 `f2ef4328929d8b8c8930e2856eef52128dd4ce3425302f04bc3c657431cc4c49`.
* Corpus: committed `raw/optimization-corpus.json`, with 3 distinct cases at
  each of 256/1024/4096 tokens and one each at 20,000/30,000 tokens.
* Each setting replayed the whole corpus three times. Thus N=9 at 256–4096
  and N=3 at 20K/30K. This preserves the harness's established small-context
  repetitions and fixed-corpus policy while adding independent full replays at
  the important 20K/30K points. Each native `/completion` request used
  `cache_prompt=false`, `temperature=0`, seed 424242, and 64 output tokens.
* `qwen-flash-next.service` and its hourly model timer were stopped during the
  direct runs. The Ollama model runner was stopped; the service was runtime
  masked/stopped to keep ratched scoring from loading GPU work. No other GPU
  process was deliberately run. The mask was removed afterward.
* Rootful container/storage metadata sanity check: neither Podman nor Docker is
  installed, hence there were no rootful retired containers, images, or
  volumes. No container or unrelated user content was inspected.

The direct command was the exact production command below, with only the final
batch arguments changed between settings:

```text
/nix/store/kkm2623mp3788y3a1l5db4qh71hvq402-llama-cpp-halo-10840/bin/llama-server
  --host 127.0.0.1 --port 8014
  --model /var/lib/qwen-flash-next/models/Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf
  --alias Qwen3.8-Flash-Next --jinja --gpu-layers 999 --flash-attn auto
  --parallel 1 --no-kv-unified --ctx-size 131072
  --ctx-checkpoints 8 --checkpoint-min-step 4096
  --cache-prompt --cache-reuse 256 --cache-ram 0 --no-cache-idle-slots
  --no-context-shift --metrics --override-tensor 'ple_key|ple_value=CPU'
  [no explicit batch flags | -b 4096 -ub 4096 | -b 8192 -ub 8192]
```

No explicit flags means b10840's effective production defaults,
`batch=2048`, `ubatch=512`.

## Results

Values are medians; parenthesized values are observed min–max. Prompt and
predicted rates are llama-server engine timings, not client estimates.

| context | setting | prompt t/s | decode t/s | N |
|---:|---|---:|---:|---:|
| 256 | default 2048/512 | 134.30 (115.88–139.27) | 23.79 (22.75–23.90) | 9 |
| 256 | 4096/4096 | 136.68 (134.40–142.96) | 24.33 (24.24–24.58) | 9 |
| 256 | 8192/8192 | 137.80 (135.08–144.59) | 24.52 (24.48–24.64) | 9 |
| 1,024 | default 2048/512 | 219.58 (210.65–222.88) | 23.18 (20.04–23.34) | 9 |
| 1,024 | 4096/4096 | 284.92 (281.64–291.99) | 23.36 (23.17–24.12) | 9 |
| 1,024 | 8192/8192 | 285.18 (283.27–292.80) | 23.24 (23.08–24.11) | 9 |
| 4,096 | default 2048/512 | 259.29 (255.63–262.05) | 22.68 (21.76–23.00) | 9 |
| 4,096 | 4096/4096 | 248.56 (242.83–255.59) | 23.09 (22.11–23.34) | 9 |
| 4,096 | 8192/8192 | 248.18 (245.96–255.11) | 23.28 (22.00–23.47) | 9 |
| 20,000 | default 2048/512 | 245.33 (245.15–246.00) | 17.80 (16.04–20.12) | 3 |
| 20,000 | 4096/4096 | 228.21 (226.89–237.30) | 20.39 (20.28–20.79) | 3 |
| 20,000 | 8192/8192 | 122.46 (119.12–123.31) | 20.75 (18.63–21.01) | 3 |
| 30,000 | default 2048/512 | 231.70 (231.31–232.77) | 19.26 (19.16–19.27) | 3 |
| 30,000 | 4096/4096 | 204.53 (202.57–214.14) | 19.83 (19.68–19.87) | 3 |
| 30,000 | 8192/8192 | 111.28 (110.87–129.57) | 19.84 (19.78–19.86) | 3 |

Relative to the reproduced default, 4096/4096 changed prompt rate by +1.8%,
+29.8%, -4.1%, -7.0%, and **-11.7%** from 256 through 30K. 8192/8192
changed it by +2.6%, +29.9%, -4.3%, **-50.1%**, and **-52.0%**. Decode was
not materially improved at the target 30K context (~19.3 versus ~19.8 t/s).
A separately monitored 30K request after restoring the production unit measured
230.42 prompt t/s and 19.92 decode t/s, corroborating the baseline.

## Greedy-output check

The existing harness's greedy settings were preserved, and exact UTF-8 output
bytes were compared by fixed corpus case across all runs. Strict identity did
**not** pass:

| context | default matching first default replay | 4096/4096 | 8192/8192 |
|---:|---:|---:|---:|
| 256 | 9/9 | 9/9 | 9/9 |
| 1,024 | 9/9 | 3/9 | 3/9 |
| 4,096 | 9/9 | 0/9 | 0/9 |
| 20,000 | 1/3 | 0/3 | 0/3 |
| 30,000 | 3/3 | 2/3 | 2/3 |

The default itself is not repeatable on the 20K corpus case, so that case cannot
serve as a strict identity oracle. More importantly, the repeatable 1K and 4K
default outputs differ under both larger-ubatch settings. At 30K, seven of the
nine total matrix outputs had sha256
`70f6503f5dfe5a3296d2202167362db1d70850fc88374099c5f49884640768c4`;
two changed one generated digit (`task-7102` to `task-7100`) and had sha256
`edd2cad953894e726da412d495d8b0684bc1a7420fe71286b3c9ccc3168b3d4c`.
This is evidence against treating a batch-size change as output-identical, not
an assertion that either continuation is semantically correct.

## Memory and fault evidence

The reliable monitor covered the restored-default 30K run: peak VRAM was
66,416,263,168 bytes (61.85 GiB), peak GTT 1,076,056,064 bytes (1.00 GiB),
and minimum `MemAvailable` was 61,838,072 KiB. Representative post-workload
snapshots were 68,217,356,288 VRAM + 3,644,071,936 GTT bytes for 4096/4096,
and 68,146,286,592 VRAM + 6,863,114,240 GTT bytes for 8192/8192. The first
attempted transient sampler had a PATH error, so these larger-setting figures
are explicitly representative snapshots rather than claimed peaks.

8192/8192 logged two Vulkan warnings at load:

```text
ggml_vulkan: Failed to allocate pinned memory
(Requested buffer size exceeds device buffer size limit: ErrorOutOfDeviceMemory)
```

It nevertheless loaded and completed all three repetitions. There was no
GGML assertion, process crash, kernel OOM, GPU reset, MES hang, or ring timeout
in the experiment window. The 4096/4096 run had none of those warnings or
faults. After cleanup, `systemctl --failed` reported zero failed units.

## Restoration and recommendation

Production was restored without changing its unit or Nix configuration. Final
state was active for `qwen-flash-next.service`, `ollama.service`, and
`qwen-flash-next-models.timer`. The qwen process again used the exact original
store path and argument vector (no `-b`/`-ub`), `/health` returned
`{"status":"ok"}`, and a native completion returned HTTP 200 with timing data.

**Recommendation: keep the production 2048/512 defaults.** Larger ubatch does
not materially improve decode, loses 12% of 30K prefill at 4096, catastrophically
loses 52% at 8192, and fails strict greedy-output identity. Do not proceed to
still larger values. The next bounded test should isolate the two controls
rather than raise them together: keep `-b 4096` while sweeping moderate
`-ub 512,1024,2048` (with the same 30K-heavy repetitions and identity gate),
or stop batching work if 30K TTFT is the overriding objective. The separately
proposed ROCm/retained-PM4 stack remains a distinct experiment and was not
started here.
