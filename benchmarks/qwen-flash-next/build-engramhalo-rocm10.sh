#!/usr/bin/env bash
# Reproducible candidate build in AMD's immutable ROCm 10 image. This only
# writes under WORK; it does not install, deploy, expose a port, or touch the
# qwen-flash-next service. Podman is intentionally an explicit prerequisite.
set -euo pipefail

REPO=https://github.com/Aristo94/EngramHalo.cpp.git
REV=15176583b358d791b7a73f210ef4ab9e167cfba7
IMAGE=docker.io/rocm/dev-ubuntu-24.04@sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374
WORK=${WORK:-"$PWD/.engramhalo-rocm10-work"}
JOBS=${JOBS:-$(nproc)}

command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }
mkdir -p "$WORK"
if [ ! -d "$WORK/src/.git" ]; then
  git clone --filter=blob:none --no-checkout "$REPO" "$WORK/src"
fi
git -C "$WORK/src" fetch --depth=1 origin "$REV"
git -C "$WORK/src" checkout --detach --force "$REV"
test "$(git -C "$WORK/src" rev-parse HEAD)" = "$REV"
rm -rf "$WORK/src/build-rocm10"

# No device is passed for compilation. This can build on a non-AMD host; only
# the later execution qualification needs /dev/kfd and /dev/dri.
podman run --rm --userns=keep-id \
  -v "$WORK/src:/src:Z" -w /src "$IMAGE" bash -ceu '
    test "$(hipconfig --version | head -1)" != ""
    cmake -S . -B build-rocm10 -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_HIP_COMPILER="$(hipconfig -l)/clang" \
      -DCMAKE_HIP_ARCHITECTURES=gfx1151 \
      -DAMDGPU_TARGETS=gfx1151 -DGPU_TARGETS=gfx1151 \
      -DGGML_NATIVE=OFF -DGGML_HIP=ON -DGGML_VULKAN=OFF -DGGML_CUDA=OFF \
      -DGGML_HIP_FORCE_MMQ=ON -DGGML_HIP_ROCWMMA_FATTN=OFF \
      -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_WEBUI=OFF \
      -DLLAMA_BUILD_TESTS=OFF -DGGML_BUILD_TESTS=OFF
    cmake --build build-rocm10 -j '"$JOBS"' --target llama-server llama-cli llama-bench
    test -x build-rocm10/bin/llama-server
  '

echo "candidate: $WORK/src/build-rocm10/bin/llama-server"
echo "source: $REV"
echo "ROCm image: $IMAGE"
