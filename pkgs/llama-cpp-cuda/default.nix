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

  # The server embeds a web UI via xxd.cmake (reads tools/ui/dist/index.html).
  # Building it properly requires npm; we only use the API so provide a stub.
  # postPatch puts it in the source tree, preBuild puts it in the cmake build tree
  # (xxd.cmake reads from the build tree, not source tree).
  postPatch = ''
    mkdir -p tools/ui/dist
    echo '<html><body>llama-server</body></html>' > tools/ui/dist/index.html
  '';
  preBuild = ''
    mkdir -p tools/ui/dist
    echo '<html><body>llama-server</body></html>' > tools/ui/dist/index.html
  '';

  cmakeFlags = [
    "-DGGML_NATIVE=OFF"
    "-DGGML_CUDA=ON"
    "-DCMAKE_CUDA_ARCHITECTURES=86"
    "-DLLAMA_BUILD_SERVER=ON"
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
