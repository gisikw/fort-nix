# llama.cpp v0.7.0 (2026-10-15), built for the decision-model server.
#
# Kept separate from pkgs/llama-cpp-cuda (pinned at b10584, Aug 2026) so that
# bumping it for decision models does not rebuild or change any other host's
# llama-server. v0.7.0 is the first tagged release with /v1/systemone serving
# for the vLLM-SR d3 family (PR #30383), Liquid d1 and pplx-decider.
#
# Build changes vs. the b10584 recipe:
#   - scripts/xxd.cmake is gone; UI assets come from scripts/ui-assets.cmake,
#     which emits an empty asset table when both BUILD_UI and the HF prebuilt
#     download are off. No postPatch needed.
#   - LLAMA_USE_PREBUILT_UI defaults ON and would fetch from a Hugging Face
#     bucket at build time; forced OFF (sandboxed build, and we want no UI).
#   - LLAMA_CURL is deprecated (HTTPS is OpenSSL now). The server never fetches
#     models here (the app's reconcile unit does, with curl + sha256), so
#     OpenSSL is off too.
#   - LLAMA_BUILD_APP (the unified `llama` binary) is off; only llama-server.
{ pkgs, cuda ? true, cudaArch ? "86" }:

let
  version = "0.7.0";
  cudaPackages = pkgs.cudaPackages_12_8;
  stdenv = if cuda then cudaPackages.backendStdenv else pkgs.stdenv;
in
stdenv.mkDerivation {
  pname = if cuda then "llama-cpp-decision-cuda" else "llama-cpp-decision";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    tag = "v${version}";
    hash = "sha256-pEDYgI3AMTU+cekvRX7NNt5wddznydQSNuerswvEpsA=";
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
  ] ++ pkgs.lib.optionals cuda [
    cudaPackages.cuda_nvcc
    pkgs.autoAddDriverRunpath
  ];

  buildInputs = pkgs.lib.optionals cuda (with cudaPackages; [
    cuda_cccl
    cuda_cudart
    libcublas
  ]);

  cmakeFlags = [
    "-DGGML_NATIVE=OFF"
    "-DLLAMA_BUILD_SERVER=ON"
    "-DLLAMA_BUILD_APP=OFF"
    "-DLLAMA_BUILD_UI=OFF"
    "-DLLAMA_USE_PREBUILT_UI=OFF"
    "-DLLAMA_OPENSSL=OFF"
    "-DLLAMA_BUILD_EXAMPLES=OFF"
    "-DLLAMA_BUILD_TESTS=OFF"
    "-DBUILD_SHARED_LIBS=ON"
    "-DLLAMA_BUILD_NUMBER=0"
    "-DLLAMA_BUILD_COMMIT=v${version}"
  ] ++ pkgs.lib.optionals cuda [
    "-DGGML_CUDA=ON"
    "-DCMAKE_CUDA_ARCHITECTURES=${cudaArch}"
  ] ++ pkgs.lib.optionals (!cuda) [
    "-DGGML_CUDA=OFF"
  ];

  postInstall = ''
    test -f $out/bin/llama-server || (echo "llama-server not found in output" && exit 1)
  '';

  meta = with pkgs.lib; {
    description = "llama.cpp v${version} for /v1/systemone decision models${optionalString cuda " (CUDA build)"}";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
