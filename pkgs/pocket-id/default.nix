{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "pocket-id";
  version = "1.16.0";
  src = pkgs.fetchurl {
    url = "https://github.com/pocket-id/pocket-id/releases/download/v1.16.0/pocket-id-linux-amd64";
    sha256 = "13lcyidj25niaq504sih5n1l2r9y9zk4pv9ri9yac3dh7c1b2cg9";
  };
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  installPhase = ''
    install -Dm755 $src $out/bin/pocket-id
  '';
}
