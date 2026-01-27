{ pkgs }:

pkgs.buildGoModule {
  pname = "runtime-package-register";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;  # No external dependencies

  meta = {
    description = "Handler to register runtime package store paths from CI";
    mainProgram = "runtime-register";
  };
}
