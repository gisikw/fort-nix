{ pkgs }:
pkgs.buildGoModule {
  pname = "fort-provisioner";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
