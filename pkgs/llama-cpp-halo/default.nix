# llama.cpp built for AMD Strix Halo (Ryzen AI Max+ / gfx1151) via Vulkan.
#
# Why upstream llama.cpp for the initial deployment:
#   * Upstream carries the architecture this host needs — `qwen4exp`
#     (Qwen3.8-Flash-Next: hybrid Gated DeltaNet + Qwen Sparse Attention and PLE
#     n-gram embeddings) — plus the server's context checkpoints.
#   * Aristo94/EngramHalo.cpp is a real, pinnable Strix-Halo fork and the current
#     performance reference. It adds ROCm sparse-QSA, MTP, and SSD-backed PLE
#     work, but is a larger patch surface. Start with a pinned upstream release
#     and lordhenry's already-used Vulkan lane; evaluate the EngramHalo pin as a
#     measured upgrade once model load and two-slot correctness are established.
#
# Why Vulkan first: lordhenry already carries `amdgpu.cwsr_enable=0` for the
# gfx1151 MES hang (ROCm #5590), and existing accelerated services use
# Vulkan/RADV. This does not claim ROCm is impossible; EngramHalo's ROCm path is
# expected to be faster and deserves a separate host soak.
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
