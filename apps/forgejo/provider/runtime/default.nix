{ pkgs }:

pkgs.buildGoModule {
  pname = "runtime-package-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  meta = with pkgs.lib; {
    description = "Runtime package distribution handler for Forgejo";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
