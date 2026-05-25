{ pkgs, domain, ffmpeg, whisperTranscribe }:

pkgs.buildGoModule {
  pname = "transcribe-provider";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;

  # Inject paths at build time
  ldflags = [
    "-X main.domain=${domain}"
    "-X main.ffmpegPath=${ffmpeg}/bin/ffmpeg"
    "-X main.whisperPath=${whisperTranscribe}/bin/whisper-transcribe"
  ];

  meta = with pkgs.lib; {
    description = "Whisper transcription handler for fort control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
