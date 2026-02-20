{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-tokens";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-WA7PLEaT7lpBkIQHXbRSrQO7mfip4mRS7xMck6lVAFs=";
  env.CGO_ENABLED = "1";
}
