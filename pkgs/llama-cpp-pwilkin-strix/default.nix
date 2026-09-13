# Exact pwilkin llama.cpp engine qualified on lordhenry with ROCm0/gfx1151.
{
  pkgs,
  runtime ? import ../pwilkin-rocm-strix { inherit pkgs; },
  rev ? "f5daaa3cfa6358e5dd398911ec741813745a5440",
  srcHash ? "sha256-9YrpYJ1K2FdDhqstcfdwWMjTl7UhBL0ZHBOP6+KbyoY=",
}:

let
  rocm = pkgs.rocmPackages;
in
rocm.llvm.clang.stdenv.mkDerivation {
  pname = "llama-cpp-pwilkin-strix";
  version = builtins.substring 0 12 rev;

  src = pkgs.fetchFromGitHub {
    owner = "pwilkin";
    repo = "llama.cpp";
    inherit rev;
    hash = srcHash;
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.curl
    runtime
    rocm.clr
    rocm.hipblas
    rocm.hipblaslt
    rocm.rocblas
    rocm.rocm-device-libs
  ];

  env = {
    ROCM_PATH = "${rocm.clr}";
    HIP_PATH = "${rocm.clr}";
    HIP_DEVICE_LIB_PATH = "${rocm.rocm-device-libs}/amdgcn/bitcode";
    AMDGPU_TARGETS = "gfx1151";
  };

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_C_COMPILER=${rocm.llvm.clang}/bin/clang"
    "-DCMAKE_CXX_COMPILER=${rocm.llvm.clang}/bin/clang++"
    "-DCMAKE_AR=${rocm.llvm.clang}/bin/llvm-ar"
    "-DCMAKE_RANLIB=${rocm.llvm.clang}/bin/llvm-ranlib"
    "-DCMAKE_HIP_COMPILER=${rocm.llvm.clang}/bin/clang"
    "-DCMAKE_HIP_ARCHITECTURES=gfx1151"
    "-DAMDGPU_TARGETS=gfx1151"
    "-DGPU_TARGETS=gfx1151"
    "-DGGML_NATIVE=OFF"
    "-DGGML_HIP=ON"
    "-DGGML_HIP_GRAPHS=ON"
    "-DGGML_HIP_NO_VMM=ON"
    "-DGGML_HIP_MMQ_MFMA=ON"
    "-DGGML_HIP_RCCL=OFF"
    "-DGGML_CUDA_FA=ON"
    "-DGGML_CUDA_FA_ALL_QUANTS=OFF"
    "-DGGML_VULKAN=OFF"
    "-DLLAMA_BUILD_SERVER=ON"
    # Avoid the upstream server UI's network fallback. The API is the only
    # production surface and the build remains sandbox-reproducible.
    "-DLLAMA_BUILD_UI=OFF"
    "-DLLAMA_BUILD_TESTS=ON"
    "-DGGML_BUILD_TESTS=OFF"
  ];

  # Match the qualified link/load order: custom HIP, custom ROCr, then the
  # pinned Nix ROCm SDK libraries. The service repeats this order explicitly.
  preConfigure = ''
    export LD_LIBRARY_PATH="${runtime}/hip/lib:${runtime}/rocr/lib:${rocm.clr}/lib:${rocm.clr}/lib64:${rocm.llvm.clang}/lib"
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export LD_LIBRARY_PATH="${runtime}/hip/lib:${runtime}/rocr/lib:${rocm.clr}/lib:${rocm.clr}/lib64:${rocm.llvm.clang}/lib:$PWD/bin"
    ./bin/test-backend-sched-ring
    runHook postCheck
  '';

  postInstall = ''
    test -x "$out/bin/llama-server"
    test -x "$out/bin/llama-bench"
    grep -q GGML_CUDA_ENABLE_UNIFIED_MEMORY ../ggml/src/ggml-cuda/ggml-cuda.cu
    grep -q 'on-direct' ../common/arg.cpp
  '';

  passthru = {
    inherit runtime;
    sourceRevision = rev;
    sourceHash = srcHash;
    gpuTarget = "gfx1151";
  };

  meta = with pkgs.lib; {
    description = "Pinned pwilkin llama.cpp HIP engine for Strix Halo gfx1151";
    homepage = "https://github.com/pwilkin/llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
