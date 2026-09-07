# llama.cpp built for AMD Strix Halo (Ryzen AI Max+ / gfx1151) via Vulkan.
#
# Why upstream llama.cpp and not a Strix-Halo fork:
#   * Upstream master already carries the architecture this host needs —
#     `qwen4exp` (Qwen3.8-Flash-Next: hybrid Gated DeltaNet + Qwen Sparse
#     Attention, PLE n-gram embeddings, MTP draft head) is in src/llama-arch.cpp,
#     and the server carries `--ctx-checkpoints` / `--checkpoint-min-step`.
#   * The "EngramHalo" material that circulates for this box is a two-star
#     ROCm-10 *container image* repo plus an empty BUILDER repo — no auditable
#     fork, no tags, nothing pinnable. Pinning a release tag of the upstream
#     tree is the reproducible option; if a fork later proves out, swap `src`
#     here and nothing else changes.
#
# Why Vulkan and not ROCm/HIP: lordhenry already boots with
# `amdgpu.cwsr_enable=0` because the gfx1151 MES firmware hangs the GPU under
# ROCm workloads (ROCm #5590), and the host's other accelerated services
# (ollama, whisper) are on the Vulkan path. Vulkan/RADV is the supported lane
# on this machine.
{
  pkgs,
  # Pinned upstream release tag. Bump tag + hash together.
  version ? "10840",
  srcHash ? "sha256-8ULPjnZAZO3JATo4Xq72x2GbCAhiK+mmT1RZUuAdg+c=",
}:

pkgs.stdenv.mkDerivation {
  pname = "llama-cpp-halo";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b${version}";
    hash = srcHash;
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.shaderc # glslc, used to compile the Vulkan shaders
    pkgs.glslang
  ];

  buildInputs = [
    pkgs.curl
    pkgs.vulkan-headers
    pkgs.vulkan-loader
    # ggml-vulkan does find_package(SPIRV-Headers) for the shader toolchain.
    pkgs.spirv-headers
    pkgs.spirv-tools
  ];

  # LLAMA_BUILD_UI=OFF skips the npm build, leaving dist/ files missing or
  # empty. Replace xxd.cmake with a version that handles both cases.
  # (Same patch as pkgs/llama-cpp-cuda; keep the two in sync.)
  postPatch = ''
        cat > scripts/xxd.cmake << 'XXDEOF'
    SET(INPUT "" CACHE STRING "Input File")
    SET(OUTPUT "" CACHE STRING "Output File")

    get_filename_component(filename "''${INPUT}" NAME)
    string(REGEX REPLACE "\\.|-" "_" name "''${filename}")

    if(NOT EXISTS "''${INPUT}")
      file(WRITE "''${OUTPUT}" "unsigned char ''${name}[] = {0x00};\nunsigned int ''${name}_len = 0;\n")
      return()
    endif()

    file(READ "''${INPUT}" hex_data HEX)
    string(LENGTH "''${hex_data}" hex_len)

    if(hex_len EQUAL 0)
      file(WRITE "''${OUTPUT}" "unsigned char ''${name}[] = {0x00};\nunsigned int ''${name}_len = 0;\n")
      return()
    endif()

    string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," hex_sequence "''${hex_data}")
    math(EXPR len "''${hex_len} / 2")
    file(WRITE "''${OUTPUT}" "unsigned char ''${name}[] = {''${hex_sequence}};\nunsigned int ''${name}_len = ''${len};\n")
    XXDEOF
  '';

  cmakeFlags = [
    "-DGGML_NATIVE=OFF"
    "-DGGML_VULKAN=ON"
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_UI=OFF"
    "-DLLAMA_BUILD_EXAMPLES=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DLLAMA_CURL=ON"
    "-DBUILD_SHARED_LIBS=ON"
  ];

  postInstall = ''
    test -f $out/bin/llama-server || (echo "llama-server not found in output" && exit 1)
  '';

  meta = with pkgs.lib; {
    description = "llama.cpp (Vulkan build, tuned for AMD Strix Halo gfx1151)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
