{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "zot";
  version = "2.1.10";
  src = pkgs.fetchurl {
    url = "https://github.com/project-zot/zot/releases/download/v2.1.10/zot-linux-amd64";
    sha256 = "sha256-t+7SKehWjZTSt6vMtcxFKJRVG/AbgQjyDf/JuUPQf3A=";
  };
  dontUnpack = true;
  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
  ];
  installPhase = ''
    install -Dm755 $src $out/bin/zot
  '';
}
