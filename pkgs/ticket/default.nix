{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "ticket";
  version = "0.3.2";

  src = pkgs.fetchFromGitHub {
    owner = "wedow";
    repo = "ticket";
    rev = "v${version}";
    hash = "sha256-XUyC7RxctKKutjtHw8iTFzjDKH5VX0O/gx09MjaH2w8=";
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;

  installPhase = ''
    install -Dm755 ticket $out/bin/tk
    wrapProgram $out/bin/tk \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.coreutils
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
