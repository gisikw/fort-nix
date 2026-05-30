{ pkgs }:

pkgs.buildGoModule {
  pname = "sse-probe";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;

  meta = with pkgs.lib; {
    description = "SSE drop-rate diagnostic monitor";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
