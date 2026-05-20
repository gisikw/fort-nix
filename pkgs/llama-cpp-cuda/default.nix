{ pkgs }:

let
  version = "9181";
  cudaPackages = pkgs.cudaPackages_12_8;
in
cudaPackages.backendStdenv.mkDerivation {
  pname = "llama-cpp-cuda";
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
    cudaPackages.cuda_nvcc
    pkgs.autoAddDriverRunpath
  ];

  buildInputs = with cudaPackages; [
    cuda_cccl
    cuda_cudart
    libcublas
    pkgs.curl
  ];

  # LLAMA_BUILD_UI=OFF skips the frontend build but xxd.cmake still runs
  # and chokes on the missing dist/index.html. Patch it to handle missing input.
  postPatch = ''
    cat > /tmp/xxd-guard << 'EOF'
if(NOT EXISTS "''${INPUT}")
  file(WRITE "''${OUTPUT}" "// stub - UI not built\nstatic const unsigned char index_html[] = {0};\nstatic const unsigned int index_html_len = 0;\n")
  return()
endif()
EOF
    cat /tmp/xxd-guard scripts/xxd.cmake > scripts/xxd.cmake.new
    mv scripts/xxd.cmake.new scripts/xxd.cmake
  '';

  cmakeFlags = [
    "-DGGML_NATIVE=OFF"
    "-DGGML_CUDA=ON"
    "-DCMAKE_CUDA_ARCHITECTURES=86"
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_UI=OFF"
    "-DLLAMA_BUILD_EXAMPLES=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DLLAMA_CURL=ON"
    "-DBUILD_SHARED_LIBS=ON"
  ];

  postInstall = ''
    # Ensure llama-server is available
    test -f $out/bin/llama-server || (echo "llama-server not found in output" && exit 1)
  '';

  meta = with pkgs.lib; {
    description = "LLM inference in C/C++ (CUDA build for RTX 3090)";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
