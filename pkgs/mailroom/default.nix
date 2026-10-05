{ pkgs }:

pkgs.buildGoModule {
  pname = "mailroom";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
