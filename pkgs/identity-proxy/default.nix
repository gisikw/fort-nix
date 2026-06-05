{ pkgs }:

pkgs.buildGoModule {
  pname = "identity-proxy";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
