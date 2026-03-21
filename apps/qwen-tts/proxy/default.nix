{ pkgs, backendURL ? "http://127.0.0.1:8880", listenAddr ? ":8882" }:

pkgs.buildGoModule {
  pname = "exo-tts-proxy";
  version = "0.2.0";

  src = ./.;

  vendorHash = null;

  ldflags = [
    "-X main.listenAddr=${listenAddr}"
    "-X main.backendURL=${backendURL}"
  ];

  meta = with pkgs.lib; {
    description = "Exo TTS proxy — routes to clone:exo voice profile";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
