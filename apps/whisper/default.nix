{ ... }:
{ config, pkgs, lib, ... }:

let
  # Model configuration
  modelName = "large-v3";
  modelHash = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2";

  modelFile = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${modelName}.bin";
    sha256 = modelHash;
  };

  # whisper-cpp with ROCm/hipBLAS support for AMD GPU
  whisper-cpp-rocm = pkgs.whisper-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = "gfx1151";
  };

  # Simple wrapper that pre-configures the model
  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    # ROCm environment for gfx1151 (Radeon 8060S)
    export HSA_OVERRIDE_GFX_VERSION=11.0.2
    export HCC_AMDGPU_TARGET=gfx1151

    # Default to outputting just the text, but allow overrides
    exec ${whisper-cpp-rocm}/bin/whisper-cli \
      --model ${modelFile} \
      --output-txt \
      "$@"
  '';

in
{
  environment.systemPackages = [
    whisper-cpp-rocm
    whisper-transcribe
  ];

  # Ensure ROCm drivers are available
  hardware.graphics.extraPackages = [ pkgs.rocmPackages.clr.icd ];
}
