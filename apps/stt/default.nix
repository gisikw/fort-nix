{ ... }:
{ pkgs, ... }:

let
  # Model configuration (same as whisper app)
  modelFile = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin";
    sha256 = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2";
  };

  # Vulkan-accelerated whisper-cpp — ROCm is unreliable on lordhenry's 8060S
  whisper-cpp-vulkan = pkgs.whisper-cpp.override {
    vulkanSupport = true;
  };

  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    exec ${whisper-cpp-vulkan}/bin/whisper-cli \
      --model ${modelFile} \
      --output-txt \
      --no-prints \
      "$@"
  '';

  port = 8787;

  stt = pkgs.buildGoModule {
    pname = "stt";
    version = "0.1.0";
    src = ./.;
    vendorHash = null;

    ldflags = [
      "-X main.ffmpegPath=${pkgs.ffmpeg}/bin/ffmpeg"
      "-X main.whisperPath=${whisper-transcribe}/bin/whisper-transcribe"
      "-X main.listenAddr=127.0.0.1:${toString port}"
    ];

    meta = with pkgs.lib; {
      description = "Speech-to-text HTTP service backed by whisper-cpp";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

in
{
  hardware.graphics.enable = true;

  systemd.services.stt = {
    description = "Speech-to-Text HTTP Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${stt}/bin/stt";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      SupplementaryGroups = [ "video" "render" ];
      PrivateTmp = true;
    };
  };

  fort.cluster.services = [{
    name = "stt";
    inherit port;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
  }];
}
