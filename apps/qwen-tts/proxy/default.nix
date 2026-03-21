{ pkgs, refAudioPath, refTranscriptPath, backendURL ? "http://127.0.0.1:8880", listenAddr ? ":8882" }:

pkgs.buildGoModule {
  pname = "exo-tts-proxy";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;

  ldflags = [
    "-X main.listenAddr=${listenAddr}"
    "-X main.backendURL=${backendURL}"
    "-X main.refAudioPath=${refAudioPath}"
    "-X main.refTranscriptPath=${refTranscriptPath}"
  ];

  meta = with pkgs.lib; {
    description = "Exo TTS proxy — bakes in voice reference for ICL cloning";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
