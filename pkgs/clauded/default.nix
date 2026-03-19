{ pkgs }:

pkgs.buildGoModule {
  pname = "clauded";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # stdlib only
}
