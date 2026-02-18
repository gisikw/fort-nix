{ pkgs, domain }:

pkgs.buildGoModule {
  pname = "tts-provider";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;

  # Inject paths at build time
  ldflags = [
    "-X main.domain=${domain}"
  ];

  meta = with pkgs.lib; {
    description = "TTS handler for fort control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
