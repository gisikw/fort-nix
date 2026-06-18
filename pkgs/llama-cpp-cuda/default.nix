{ pkgs, cuda ? true, cudaArch ? "86" }:

let
  version = "9181";
  cudaPackages = pkgs.cudaPackages_12_8;
  stdenv = if cuda then cudaPackages.backendStdenv else pkgs.stdenv;
in
stdenv.mkDerivation {
  pname = if cuda then "llama-cpp-cuda" else "llama-cpp";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "b${version}";
    hash = "sha256-FQGfvpgKXXyShv6pZC4e9C6u7aTC8vFhyqTnNEwWnDI=";
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
  ] ++ pkgs.lib.optionals cuda [
    cudaPackages.cuda_nvcc
    pkgs.autoAddDriverRunpath
  ];

  buildInputs = [
    pkgs.curl
  ] ++ pkgs.lib.optionals cuda (with cudaPackages; [
    cuda_cccl
    cuda_cudart
    libcublas
  ]);

  # LLAMA_BUILD_UI=OFF skips the npm build, leaving dist/ files missing or
  # empty. Replace xxd.cmake with a version that handles both cases.
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
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_UI=OFF"
    "-DLLAMA_BUILD_EXAMPLES=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DLLAMA_CURL=ON"
    "-DBUILD_SHARED_LIBS=ON"
  ] ++ pkgs.lib.optionals cuda [
    "-DGGML_CUDA=ON"
    "-DCMAKE_CUDA_ARCHITECTURES=${cudaArch}"
  ] ++ pkgs.lib.optionals (!cuda) [
    "-DGGML_CUDA=OFF"
  ];

  postInstall = ''
    # Ensure llama-server is available
    test -f $out/bin/llama-server || (echo "llama-server not found in output" && exit 1)
  '';

  meta = with pkgs.lib; {
    description = "LLM inference in C/C++${optionalString cuda " (CUDA build)"}";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
