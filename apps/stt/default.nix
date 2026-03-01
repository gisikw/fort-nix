{ ... }:
{ pkgs, ... }:

let
  # Model configuration (same as whisper app)
  modelFile = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin";
    sha256 = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2";
  };

  # whisper-cpp with ROCm/hipBLAS support for AMD GPU
  gpuTargets = "gfx1102;gfx1151";

  whisper-cpp-rocm = (pkgs.whisper-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = gpuTargets;
  }).overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DGGML_HIP=ON"
      "-DGGML_HIPBLAS=ON"
      "-DAMDGPU_TARGETS=${gpuTargets}"
    ];
  });

  whisper-transcribe = pkgs.writeShellScriptBin "whisper-transcribe" ''
    export HSA_OVERRIDE_GFX_VERSION=11.0.2
    export HCC_AMDGPU_TARGET=gfx1151
    exec ${whisper-cpp-rocm}/bin/whisper-cli \
      --model ${modelFile} \
      --output-txt \
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
  # ROCm drivers (merged with whisper app's identical declaration)
  hardware.graphics.extraPackages = [ pkgs.rocmPackages.clr.icd ];

  systemd.services.stt = {
    description = "Speech-to-Text HTTP Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HSA_OVERRIDE_GFX_VERSION = "11.0.2";
      HCC_AMDGPU_TARGET = "gfx1151";
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${stt}/bin/stt";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
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
