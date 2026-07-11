{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-certcheck";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  meta = with pkgs.lib; {
    description = "Certificate lifecycle decisions (renewal, freshness, install) for the fort control plane";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
