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

  # Vulkan-accelerated whisper-cpp — ROCm is unreliable on lordhenry's 8060S
  whisper-cpp-vulkan = pkgs.whisper-cpp.override {
    vulkanSupport = true;
  };

  # Simple wrapper that pre-configures the model
  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    exec ${whisper-cpp-vulkan}/bin/whisper-cli \
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
  hardware.graphics.enable = true;

  environment.systemPackages = [
    pkgs.ffmpeg
    whisper-cpp-vulkan
    whisper-transcribe
  ];

  # Expose transcribe capability for cluster-wide audio transcription
  fort.host.capabilities.transcribe = {
    handler = "${transcribeProvider}/bin/transcribe-provider";
    mode = "rpc";
    allowed = [ "dev-sandbox" ];
    description = "Transcribe audio file and upload result to target host";
  };
}
