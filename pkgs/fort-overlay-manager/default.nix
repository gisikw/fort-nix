{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-overlay-manager";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
