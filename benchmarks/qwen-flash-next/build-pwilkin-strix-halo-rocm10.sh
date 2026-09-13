#!/usr/bin/env bash
# Build the pinned pwilkin Strix Halo runtime and engine in the immutable AMD
# ROCm 10 development image. No GPU device is passed during compilation.
set -Eeuo pipefail

ROCM_REPO=https://github.com/pwilkin/rocm-systems.git
ROCM_REV=7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1
LLAMA_REPO=https://github.com/pwilkin/llama.cpp.git
LLAMA_REV=f5daaa3cfa6358e5dd398911ec741813745a5440
IMAGE=docker.io/rocm/dev-ubuntu-24.04@sha256:a90cf047f615abe70fbef83c64def0a2d549ef37a39c8ea545430aba4981b374
WORK=${WORK:-"$PWD/.pwilkin-strix-halo-rocm10-work"}
JOBS=${JOBS:-16}

command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }
mkdir -p "$WORK/work" "$WORK/podman-root" "$WORK/podman-runroot" \
  "$WORK/home/.config/containers"
chmod 700 "$WORK" "$WORK/work" "$WORK/podman-root" \
  "$WORK/podman-runroot" "$WORK/home"
cat > "$WORK/home/.config/containers/policy.json" <<'JSON'
{"default":[{"type":"reject"}],"transports":{"docker":{"docker.io/rocm/dev-ubuntu-24.04":[{"type":"insecureAcceptAnything"}]}}}
JSON
PODMAN=(podman --root "$WORK/podman-root" --runroot "$WORK/podman-runroot")

HOME="$WORK/home" "${PODMAN[@]}" pull --signature-policy \
  "$WORK/home/.config/containers/policy.json" "$IMAGE"
HOME="$WORK/home" "${PODMAN[@]}" run --rm --security-opt label=disable \
  -v "$WORK/work:/work" -w /work "$IMAGE" bash -ceu '
    export DEBIAN_FRONTEND=noninteractive
    ROCM_ROOT=/opt/rocm
    ROCM_REV='"$ROCM_REV"'
    LLAMA_REV='"$LLAMA_REV"'
    JOBS='"$JOBS"'

    # These are the unpinned distro prerequisites used by upstream install.sh;
    # they remain inside the disposable container. Source, SDK and target pins
    # are immutable, but exact binary hashes can still vary with these packages
    # and llama.cpp UI asset availability.
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake curl git libcurl4-openssl-dev \
      libdrm-dev libdw-dev libelf-dev libgl-dev libnuma-dev libpciaccess-dev \
      libssl-dev libudev-dev libzstd-dev ninja-build pciutils pkg-config \
      python3 python3-pip python3-venv xxd zlib1g-dev

    python3 -m venv /work/venv
    /work/venv/bin/pip install --disable-pip-version-check --upgrade pip
    /work/venv/bin/pip install --disable-pip-version-check CppHeaderParser==2.7.4
    mkdir -p /work/src /work/build /work/runtime

    if [[ ! -d /work/src/rocm-systems/.git ]]; then
      git clone --filter=blob:none --single-branch --branch ilintar-experiments \
        '"$ROCM_REPO"' /work/src/rocm-systems
    fi
    if [[ ! -d /work/src/llama.cpp/.git ]]; then
      git clone --filter=blob:none --single-branch --branch strix-halo \
        '"$LLAMA_REPO"' /work/src/llama.cpp
    fi
    git -C /work/src/rocm-systems fetch origin "$ROCM_REV"
    git -C /work/src/rocm-systems checkout --detach --force "$ROCM_REV"
    git -C /work/src/llama.cpp fetch origin "$LLAMA_REV"
    git -C /work/src/llama.cpp checkout --detach --force "$LLAMA_REV"
    test "$(git -C /work/src/rocm-systems rev-parse HEAD)" = "$ROCM_REV"
    test "$(git -C /work/src/llama.cpp rev-parse HEAD)" = "$LLAMA_REV"

    rocr=/work/runtime/rocr
    hip=/work/runtime/hip
    rb=/work/build/rocr
    hb=/work/build/hip
    lb=/work/build/llama.cpp
    rm -rf "$rocr" "$hip" "$rb" "$hb" "$lb"

    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" cmake \
      -S /work/src/rocm-systems/projects/rocr-runtime -B "$rb" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$rocr" \
      -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$ROCM_ROOT" \
      -DBUILD_SHARED_LIBS=ON
    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" cmake --build "$rb" --parallel "$JOBS"
    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" cmake --install "$rb"
    test -e "$rocr/lib/libhsa-runtime64.so.1"

    libs="$rocr/lib:$ROCM_ROOT/lib:$ROCM_ROOT/lib64:$ROCM_ROOT/lib/llvm/lib"
    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" LD_LIBRARY_PATH="$libs" cmake \
      -S /work/src/rocm-systems/projects/clr -B "$hb" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$hip" \
      -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$rocr;$ROCM_ROOT" \
      -DCLR_BUILD_HIP=ON -DCLR_BUILD_OCL=OFF -DHIP_PLATFORM=amd \
      -DHIP_COMMON_DIR=/work/src/rocm-systems/projects/hip \
      -DHIPCC_BIN_DIR="$ROCM_ROOT/bin" -DLLVM_ROOT="$ROCM_ROOT/lib/llvm" \
      -DClang_ROOT="$ROCM_ROOT/lib/llvm" -DROCM_PATH="$rocr" \
      -Dhsa-runtime64_DIR="$rocr/lib/cmake/hsa-runtime64" \
      -DROCCLR_ENABLE_HSA=ON -DROCCLR_ENABLE_PAL=OFF \
      -DHIP_ENABLE_ROCPROFILER_REGISTER=ON -DUSE_PROF_API=ON -D__HIP_ENABLE_PCH=ON
    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" LD_LIBRARY_PATH="$libs" \
      cmake --build "$hb" --parallel "$JOBS"
    PATH="/work/venv/bin:$ROCM_ROOT/bin:$PATH" LD_LIBRARY_PATH="$libs" cmake --install "$hb"
    test -e "$hip/lib/libamdhip64.so.7"

    PATH="$ROCM_ROOT/bin:$PATH" ROCM_PATH="$ROCM_ROOT" cmake \
      -S /work/src/llama.cpp -B "$lb" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH="$ROCM_ROOT" -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 \
      -DGGML_HIP_GRAPHS=ON -DGGML_HIP_NO_VMM=ON -DGGML_HIP_MMQ_MFMA=ON \
      -DGGML_HIP_RCCL=OFF -DGGML_CUDA_FA=ON \
      -DGGML_CUDA_FA_ALL_QUANTS=OFF -DGGML_VULKAN=OFF -DLLAMA_BUILD_TESTS=ON
    PATH="$ROCM_ROOT/bin:$PATH" ROCM_PATH="$ROCM_ROOT" \
      cmake --build "$lb" --parallel "$JOBS" \
      --target llama-server llama-bench test-backend-sched-ring
    "$lb/bin/test-backend-sched-ring"

    runtime="$hip/lib:$rocr/lib:$ROCM_ROOT/lib:$ROCM_ROOT/lib64:$ROCM_ROOT/lib/llvm/lib:$lb/bin"
    LD_LIBRARY_PATH="$runtime" ldd "$lb/bin/libggml-hip.so.0" | tee /work/ldd-libggml-hip.txt
    grep -F "$hip/lib/libamdhip64.so" /work/ldd-libggml-hip.txt
    grep -F "$rocr/lib/libhsa-runtime64.so" /work/ldd-libggml-hip.txt
    sha256sum "$lb/bin/llama-server" "$lb/bin/llama-bench" \
      "$hip/lib/libamdhip64.so.7" "$rocr/lib/libhsa-runtime64.so.1" \
      | tee /work/build-sha256.txt
  '

echo "candidate: $WORK/work/build/llama.cpp/bin/llama-bench"
echo "custom HIP: $WORK/work/runtime/hip"
echo "custom ROCr: $WORK/work/runtime/rocr"
echo "ROCm image: $IMAGE"
echo "bounded Podman store: $WORK/podman-root"
du -sB1 "$WORK"
