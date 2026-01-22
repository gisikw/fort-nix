{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-upload";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  meta = with pkgs.lib; {
    description = "Fort file upload handler (FastCGI)";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
