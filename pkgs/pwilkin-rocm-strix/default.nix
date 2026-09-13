# Custom ROCr/HIP runtime qualified on lordhenry for gfx1151.
#
# This builds the two runtime components from the exact pwilkin source revision.
# The pinned Fort ROCm SDK is a build-time ABI/toolchain input only; the service
# puts these custom libraries first at runtime. No container or retained
# benchmark artifact is part of the closure.
{
  pkgs,
  rev ? "7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1",
  srcHash ? "sha256-URmOwL8itq2lwzfkRD4QtRuoAcBRHva2sLJ+vl0wjbE=",
}:

let
  rocm = pkgs.rocmPackages;
in
rocm.llvm.clang.stdenv.mkDerivation {
  pname = "pwilkin-rocm-strix-runtime";
  version = builtins.substring 0 12 rev;

  src = pkgs.fetchFromGitHub {
    owner = "pwilkin";
    repo = "rocm-systems";
    inherit rev;
    hash = srcHash;
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3Packages.cppheaderparser
  ];

  buildInputs = [
    pkgs.elfutils
    pkgs.libdrm
    pkgs.libffi
    pkgs.libglvnd
    pkgs.libglvnd.dev
    pkgs.numactl
    pkgs.numactl.dev
    pkgs.libpciaccess
    pkgs.libxml2
    pkgs.systemd
    pkgs.xorg.libX11
    pkgs.xorg.xorgproto
    pkgs.zlib
    pkgs.zstd
    rocm.clr
    rocm.llvm.clang
    rocm.llvm.clang-unwrapped.dev
    rocm.llvm.llvm.dev
    rocm.rocprofiler-register
  ];

  dontUseCmakeConfigure = true;
  NIX_CFLAGS_COMPILE = "-I${pkgs.numactl.dev}/include -I${pkgs.libglvnd.dev}/include -I${pkgs.xorg.libX11.dev}/include -I${pkgs.xorg.xorgproto}/include";

  # ROCm 10's runtime source also prebuilds gfx12/gfx12.5 trap/blit objects.
  # Fort's pinned LLVM 19 does not know those future ISAs, and lordhenry needs
  # only the gfx11-compatible objects. Restrict generated runtime code to the
  # gfx1100 family object used by gfx1151; this does not alter host C++ support.
  postPatch = ''
    patchShebangs projects
    substituteInPlace projects/rocr-runtime/runtime/hsa-runtime/core/runtime/trap_handler/CMakeLists.txt \
      --replace-fail 'set (TARGET_DEVS "gfx900;gfx942;gfx950;gfx1010;gfx1030;gfx1100;gfx1200;gfx1250")' \
                     'set (TARGET_DEVS "gfx900;gfx942;gfx950;gfx1010;gfx1030;gfx1100")'
    substituteInPlace projects/rocr-runtime/runtime/hsa-runtime/core/runtime/blit_shaders/CMakeLists.txt \
      --replace-fail 'set (TARGET_DEVS "gfx900;gfx1010;gfx1030;gfx1100;gfx1200;gfx1250")' \
                     'set (TARGET_DEVS "gfx900;gfx1010;gfx1030;gfx1100")'
    # Keep the fixed-size dispatch table valid for unreachable gfx12 entries
    # while avoiding references to objects LLVM 19 cannot assemble. gfx1151
    # selects the unchanged gfx11 entries.
    substituteInPlace projects/clr/hipamd/src/hiprtc/CMakeLists.txt \
      --replace-fail 'COMMAND ''${clang} -O3' \
                     'COMMAND ''${clang} -resource-dir=${rocm.llvm.clang-unwrapped.lib}/lib/clang/19 -O3'
    # COMGR 3.2 added SPIR-V-only actions. llama.cpp loads native gfx1151 HIP
    # bundles and never enters these branches; retain a compileable fallback
    # against Fort's pinned COMGR 3.0 without changing native HIP behavior.
    substituteInPlace projects/clr/hipamd/src/hip_comgr_helper.cpp \
      --replace-warn 'AMD_COMGR_ACTION_COMPILE_SOURCE_TO_SPIRV' \
                     'AMD_COMGR_ACTION_COMPILE_SOURCE_TO_BC'
    substituteInPlace projects/clr/hipamd/src/hip_fatbin.cpp \
      --replace-warn 'AMD_COMGR_ACTION_COMPILE_SPIRV_TO_RELOCATABLE' \
                     'AMD_COMGR_ACTION_COMPILE_SOURCE_TO_RELOCATABLE'
    substituteInPlace \
      projects/clr/rocclr/cmake/ROCclrLC.cmake \
      projects/clr/hipamd/src/CMakeLists.txt \
      projects/clr/hipamd/src/hiprtc/CMakeLists.txt \
      --replace-warn 'find_package(amd_comgr 3.2' 'find_package(amd_comgr 3.0'
    substituteInPlace projects/rocr-runtime/runtime/hsa-runtime/core/runtime/amd_gpu_agent.cpp \
      --replace-warn 'kCodeTrapHandlerV2_1250' 'kCodeTrapHandlerV2_11' \
      --replace-warn 'kCodeTrapHandlerV2_12' 'kCodeTrapHandlerV2_11' \
      --replace-warn 'kCodeCopyAligned1250' 'kCodeCopyAligned11' \
      --replace-warn 'kCodeCopyAligned12' 'kCodeCopyAligned11' \
      --replace-warn 'kCodeCopyMisaligned1250' 'kCodeCopyMisaligned11' \
      --replace-warn 'kCodeCopyMisaligned12' 'kCodeCopyMisaligned11' \
      --replace-warn 'kCodeFill1250' 'kCodeFill11' \
      --replace-warn 'kCodeFill12' 'kCodeFill11'
  '';

  buildPhase = ''
    runHook preBuild
    export PATH=${pkgs.python3Packages.cppheaderparser}/bin:${rocm.llvm.clang}/bin:$PATH
    export ROCM_SDK=${rocm.clr}

    cmake -S projects/rocr-runtime -B build-rocr -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$NIX_CFLAGS_COMPILE" \
      -DCMAKE_CXX_FLAGS="$NIX_CFLAGS_COMPILE" \
      -DCMAKE_INSTALL_PREFIX="$out/rocr" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_PREFIX_PATH="$ROCM_SDK;${rocm.llvm.clang-unwrapped.dev};${rocm.llvm.llvm.dev}" \
      -DClang_DIR="${rocm.llvm.clang-unwrapped.dev}/lib/cmake/clang" \
      -DLLVM_DIR="${rocm.llvm.llvm.dev}/lib/cmake/llvm" \
      -DIMAGE_SUPPORT=OFF \
      -DTARGET_DEVICES=gfx1151 \
      -DBUILD_SHARED_LIBS=ON
    cmake --build build-rocr --parallel "$NIX_BUILD_CORES"
    cmake --install build-rocr

    custom_rocr="$out/rocr"
    export LD_LIBRARY_PATH="$custom_rocr/lib:${rocm.clr}/lib:${rocm.clr}/lib64:${rocm.llvm.clang}/lib"
    # PCH embeds ROCm-10-only clang builtins. It affects HIPRTC header
    # startup, not llama.cpp execution, and cannot be generated by LLVM 19.
    cmake -S projects/clr -B build-hip -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$NIX_CFLAGS_COMPILE" \
      -DCMAKE_CXX_FLAGS="$NIX_CFLAGS_COMPILE" \
      -DCMAKE_INSTALL_PREFIX="$out/hip" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_PREFIX_PATH="$custom_rocr;$ROCM_SDK" \
      -DCLR_BUILD_HIP=ON \
      -DCLR_BUILD_OCL=OFF \
      -DHIP_PLATFORM=amd \
      -DHIP_COMMON_DIR="$PWD/projects/hip" \
      -DHIPCC_BIN_DIR="${rocm.clr}/bin" \
      -DLLVM_ROOT="${rocm.llvm.clang-unwrapped}" \
      -DClang_ROOT="${rocm.llvm.clang-unwrapped}" \
      -DHIP_LLVM_ROOT="${rocm.llvm.clang}" \
      -DROCM_PATH="$custom_rocr" \
      -Dhsa-runtime64_DIR="$custom_rocr/lib/cmake/hsa-runtime64" \
      -DROCCLR_ENABLE_HSA=ON \
      -DROCCLR_ENABLE_PAL=OFF \
      -DHIP_ENABLE_ROCPROFILER_REGISTER=ON \
      -DUSE_PROF_API=ON \
      -D__HIP_ENABLE_PCH=OFF
    cmake --build build-hip --parallel "$NIX_BUILD_CORES"
    cmake --install build-hip
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    test -e "$out/rocr/lib/libhsa-runtime64.so.1"
    test -e "$out/hip/lib/libamdhip64.so.7"
    runHook postInstall
  '';

  passthru = {
    sourceRevision = rev;
    sourceHash = srcHash;
  };

  meta = with pkgs.lib; {
    description = "Pinned pwilkin ROCr/HIP runtime for Strix Halo";
    homepage = "https://github.com/pwilkin/rocm-systems";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
