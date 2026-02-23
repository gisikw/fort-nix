{ rootManifest, ... }:
{ config, pkgs, lib, ... }:

let
  domain = rootManifest.fortConfig.settings.domain;
  # Model configuration
  modelName = "large-v3";
  modelHash = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2";

  modelFile = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${modelName}.bin";
    sha256 = modelHash;
  };

  # whisper-cpp with ROCm/hipBLAS support for AMD GPU
  # HIP runtime detects gfx1102, HSA reports gfx1151 - compile for both
  gpuTargets = "gfx1102;gfx1151";

  whisper-cpp-rocm = (pkgs.whisper-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = gpuTargets;
  }).overrideAttrs (old: {
    # Force HIP backend build - both old and new cmake flag names
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DGGML_HIP=ON"
      "-DGGML_HIPBLAS=ON"
      "-DAMDGPU_TARGETS=${gpuTargets}"
    ];
  });

  # Simple wrapper that pre-configures the model
  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    # ROCm environment for gfx1151 (Radeon 8060S)
    export HSA_OVERRIDE_GFX_VERSION=11.0.0
    export HCC_AMDGPU_TARGET=gfx1151

    # Default to outputting just the text, but allow overrides
    exec ${whisper-cpp-rocm}/bin/whisper-cli \
      --model ${modelFile} \
      --output-txt \
      "$@"
  '';

  # Go handler for transcribe capability
  transcribeProvider = import ./provider {
    inherit pkgs domain;
    ffmpeg = pkgs.ffmpeg;
    whisperTranscribe = whisper-transcribe;
  };

in
{
  environment.systemPackages = [
    pkgs.ffmpeg
    whisper-cpp-rocm
    whisper-transcribe
  ];

  # Ensure ROCm drivers are available
  hardware.graphics.extraPackages = [ pkgs.rocmPackages.clr.icd ];

  # Expose transcribe capability for cluster-wide audio transcription
  fort.host.capabilities.transcribe = {
    handler = "${transcribeProvider}/bin/transcribe-provider";
    mode = "rpc";
    allowed = [ "dev-sandbox" ];
    description = "Transcribe audio file and upload result to target host";
  };
}
