# Experimental llama.cpp build for AMD Strix Halo. This is intentionally not
# wired into any production service; benchmarks/qwen-flash-next/ records the
# qualification evidence needed before considering that.
{
  pkgs,
  rev ? "7449a0fe9710ab584c5f9a6d25e7a31eea2708b8",
  srcHash ? "sha256-JKbzy7FNPNVl6cKZEKokjHJ5RlXamhaOMPnddUZSyd0=",
}:

pkgs.stdenv.mkDerivation {
  pname = "llama-cpp-strix";
  version = builtins.substring 0 12 rev;

  src = pkgs.fetchFromGitHub {
    owner = "halo-box";
    repo = "strix-llama.cpp";
    inherit rev;
    hash = srcHash;
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.shaderc
    pkgs.glslang
  ];

  buildInputs = [
    pkgs.curl
    pkgs.vulkan-headers
    pkgs.vulkan-loader
    pkgs.spirv-headers
    pkgs.spirv-tools
  ];

  # LLAMA_BUILD_UI=OFF does not guarantee that generated dist files exist.
  # Keep this identical to the qualified stock package.
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
    test -x $out/bin/llama-server
    $out/bin/llama-server --version
  '';

  meta = with pkgs.lib; {
    description = "Experimental halo-box Strix Halo llama.cpp Vulkan build";
    homepage = "https://github.com/halo-box/strix-llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
