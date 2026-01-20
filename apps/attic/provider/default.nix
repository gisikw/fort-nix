{ pkgs, cacheURL, cacheName }:

pkgs.buildGoModule {
  pname = "attic-token-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject configuration at build time via ldflags
  ldflags = [
    "-X main.defaultAtticClientPath=${pkgs.attic-client}/bin/attic"
    "-X main.cacheURL=${cacheURL}"
    "-X main.cacheName=${cacheName}"
  ];

  meta = with pkgs.lib; {
    description = "Attic binary cache token distribution handler";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
