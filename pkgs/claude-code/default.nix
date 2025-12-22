{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "claude-code";
  version = "2.0.67";
  src = pkgs.fetchurl {
    url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.0.67/linux-x64/claude";
    sha256 = "1wr6cxrf608z22adhjwvx1rinxyv3rbjls00j3si8f6zsmwj58dj";
  };
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  installPhase = ''
    install -Dm755 $src $out/bin/claude
  '';
}
