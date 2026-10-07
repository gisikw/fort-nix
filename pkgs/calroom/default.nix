{ pkgs }:

pkgs.buildGoModule {
  pname = "calroom";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
