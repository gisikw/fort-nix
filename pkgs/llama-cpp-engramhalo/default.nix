# Experimental only: this package is deliberately not imported by any NixOS
# module.  It requires a ROCm 10 package set supplied by a future nixpkgs pin
# or overlay; fort's pinned nixpkgs has ROCm 6.4.3 and must not be substituted.
{
  pkgs,
  rocmPackages ? pkgs.rocmPackages,
  rev ? "15176583b358d791b7a73f210ef4ab9e167cfba7",
  srcHash ? "sha256-vV6OYo8j6JeJn7c4ICCAmnDDkrqfhFv2F/4olW24k/g=",
}:

let
  lib = pkgs.lib;
  rocmVersion = rocmPackages.clr.version;
  rocm10 = lib.versions.major rocmVersion == "10";
in
assert lib.assertMsg rocm10 ''
  llama-cpp-engramhalo requires ROCm 10.x; supplied rocmPackages.clr is
  ${rocmVersion}. Provide a pinned ROCm 10 nixpkgs/overlay; do not use ROCm 7.x.
'';
rocmPackages.llvm.clang.stdenv.mkDerivation {
  pname = "llama-cpp-engramhalo-rocm";
  version = builtins.substring 0 12 rev;

  src = pkgs.fetchFromGitHub {
    owner = "Aristo94";
    repo = "EngramHalo.cpp";
    inherit rev;
    hash = srcHash;
  };

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
  ];
  buildInputs = with rocmPackages; [
    clr
    hipblas
    hipblaslt
    rocblas
    rocm-device-libs
  ];

  env = {
    ROCM_PATH = "${rocmPackages.clr}";
    HIP_PATH = "${rocmPackages.clr}";
    HIP_DEVICE_LIB_PATH = "${rocmPackages.rocm-device-libs}/amdgcn/bitcode";
    AMDGPU_TARGETS = "gfx1151";
  };

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_HIP_COMPILER=${rocmPackages.llvm.clang}/bin/clang"
    "-DCMAKE_HIP_ARCHITECTURES=gfx1151"
    "-DAMDGPU_TARGETS=gfx1151"
    "-DGPU_TARGETS=gfx1151"
    "-DGGML_NATIVE=OFF"
    "-DGGML_HIP=ON"
    "-DGGML_VULKAN=OFF"
    "-DGGML_CUDA=OFF"
    "-DGGML_HIP_FORCE_MMQ=ON"
    "-DGGML_HIP_ROCWMMA_FATTN=OFF"
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_WEBUI=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DGGML_BUILD_TESTS=OFF"
  ];

  postInstall = ''
    test -x "$out/bin/llama-server"
    test -x "$out/bin/llama-bench"
  '';

  meta = {
    description = "Experimental EngramHalo.cpp HIP build for ROCm 10 and gfx1151";
    homepage = "https://github.com/Aristo94/EngramHalo.cpp";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
