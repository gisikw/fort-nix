{ pkgs }:

pkgs.stdenvNoCC.mkDerivation {
  pname = "herdr";
  version = "0.8.0";
  src = pkgs.fetchurl {
    url = "https://github.com/herdrdev/herdr/releases/download/v0.8.0/herdr-linux-x86_64";
    sha256 = "b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28";
  };
  dontUnpack = true;
  installPhase = ''
    install -Dm755 "$src" "$out/bin/herdr"
  '';
}
