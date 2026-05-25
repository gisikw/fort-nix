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

  # Vulkan-accelerated whisper-cpp — ROCm is unreliable on lordhenry's 8060S
  whisper-cpp-vulkan = pkgs.whisper-cpp.override {
    vulkanSupport = true;
  };

  # Silero VAD silence stripper (CPU-only, ~165x real-time)
  vad-strip = import ../../pkgs/vad-strip { inherit pkgs; };

  # Wrapper that runs VAD silence stripping then whisper-cli
  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    # Strip silence via Silero VAD before transcription (non-fatal)
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-f" ] && [ -f "$arg" ]; then
        ${vad-strip}/bin/vad-strip "$arg" || true
        break
      fi
      prev="$arg"
    done
    exec ${whisper-cpp-vulkan}/bin/whisper-cli \
      --model ${modelFile} \
      --output-txt \
      "$@"
  '';

in
{
  hardware.graphics.enable = true;

  environment.systemPackages = [
    pkgs.ffmpeg
    whisper-cpp-vulkan
    whisper-transcribe
  ];

}
