{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "ticket";
  version = "0.3.2-unstable-2026-02-03";

  src = pkgs.fetchFromGitHub {
    owner = "wedow";
    repo = "ticket";
    rev = "f4403d9fb1610493b4a003b62bb6063716c2d96d";
    hash = "sha256-3lDrrUqhliClq0Xp5nDW15nAgiddbGLm8zY5w/++IaM=";
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;

  installPhase = ''
    install -Dm755 ticket $out/bin/tk
    wrapProgram $out/bin/tk \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.ripgrep
      ]}
  '';

  meta = with pkgs.lib; {
    description = "Git-native issue tracker for AI agents";
    homepage = "https://github.com/wedow/ticket";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
