# Qwen3.8-Flash-Next Strix Halo optimization candidates

Audit date: 2026-09-08 UTC. Production comparison point is upstream
`ggml-org/llama.cpp` b10840, Vulkan/RADV, the exact three-shard Unsloth
`UD-Q3_K_XL` GGUF (89,975,329,280 bytes), one slot, 131072 context.

| candidate | exact revision/artifact | exact deployed GGUF? | build/load status | evidence and disposition |
|---|---|---:|---|---|
| stock llama.cpp | b10840 | yes | production baseline | 220.72 pp t/s, 135.95 s TTFT, 19.19 decode t/s at 30k fixed prompt |
| halo-box/strix-llama.cpp | `7449a0fe9710ab584c5f9a6d25e7a31eea2708b8` | yes | Nix build and real lordhenry A/B passed | 221.67 pp t/s, 135.38 s TTFT, 19.08 decode t/s at 30k: noise-sized, not a production upgrade. Useful 256-4k prefill gains, but no target-context win and one advertised typed-content capability is lost. |
| peonist-ai/halogen-flash-server | repo `0208581a5a0c54c53fc11f2e9e06622f168f5b6f` / image 0.4.4 digest `sha256:b5d60eb35ad1eaeff782cec1455cfd08a6716a1be188bb407dc132ed7edf2df9` | **no** | image metadata/scripts audited; not run | Closed binary engine and front end are absent from public repo, so it cannot be source-built. It hard-requires `.hgn`, not GGUF. Separate checkpoint is 124,068,083,904 bytes plus 2,477,677,120-byte quality overlay and differs in precision (5.53 bpw). Published speed is interesting but not an apples-to-apples result. No numbers credited here. |
| myhacsint/llama.cpp production snapshot | `2dff8596dcb7bdf765d24d44e1155d51f04c82b7` (compiled snapshot `38afc198…`, b10685 lineage) | yes | source/rebuild recipe audited; not on-box tested | Vulkan snapshot adds Qwen4Exp state/indexer work and external shared-MTP support. Older than b10840 and its principal advantage requires the separate 2.786 GB MTP sidecar. No credible reason to expect stock-prefill improvement without MTP; integration is moderate and regression surface is larger than the measured halo-box candidate. |
| EngramHalo.cpp | `60bce1a304394203e4e4285cf795138026d9f793` | likely loads, but published runs use other quant/config | source/container recipe audited; not on-box tested | ROCm/HIP-only recommendation. Published gains use IQ3_XXS/IQ4_XS, q8 KV, MTP sidecar and resident/SSD engram modes, not this UD-Q3_K_XL Vulkan baseline. Its own docs call the full fork a Vulkan net loss. Requires ROCm 7.14 host qualification and `HIP_LAUNCH_BLOCKING`/gfx1151 correctness work. High integration effort. |
| strix-llama speculative prefill | included in halo-box tree, `--spec-prefill` | target GGUF yes, but needs a separate 2B estimator | feature audited; deliberately not benchmarked as equivalent | Drops target prompt tokens (e.g. keep 30%), so it is lossy and changes effective prompt execution. It may lower TTFT but cannot be called a prefill throughput win under the exact-token correctness requirement. |
| halo-box `strix/vulkan-stack-only` | `792acdfd09bbe10f6d7f509e50d338f6f26ec890` | probably | unmerged moving branch, not deployed | Carries a large additional experimental Vulkan stack beyond audited master, including env/default-gated Qwen/DeltaNet MoE work. Not selected for the controlled A/B because supervisor authorization named `7449a0fe`; it needs its own source freeze and correctness gate. |

## Reproducible Strix build

`pkgs/llama-cpp-strix/default.nix` pins the tested source and hash and uses the
same Vulkan toolchain and CMake policy as `pkgs/llama-cpp-halo/default.nix`:

```text
-DGGML_NATIVE=OFF -DGGML_VULKAN=ON
-DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_UI=OFF
-DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF
-DLLAMA_CURL=ON -DBUILD_SHARED_LIBS=ON
```

Local Nix output:

```text
/nix/store/nra91nxz4hyqjlxndv5bpirlhhpbfj0c-llama-cpp-strix-7449a0fe9710
llama-server sha256 d6f5de7d4b1e67ed3b3fbd957982c1c04e697c580db7cf29c4707b4df1c36b40
```

The candidate deployment commit was `75378b3b0a49d3f434b89047e0105a128b60b010`.
Production was restored by forward revert
`c7a181708f73e6df76f03830059f6ecf73c9042b`; no reset or force push was used.
