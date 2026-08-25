{ pkgs }:

let
  pi-coding-agent = import ../pi-coding-agent { inherit pkgs; };
in
pkgs.buildGoModule rec {
  pname = "golem";
  version = "0.1.0-187a53d";

  src = pkgs.fetchFromGitHub {
    owner = "gisikw";
    repo = "golem";
    rev = "187a53d5baa181247550255f4d43f430155cb125";
    hash = "sha256-7jAdmkDFydwqVkhWIrW10sTXsWQqtp9laU4/jcSFHiI=";
  };

  vendorHash = "sha256-oeJJeFerfb5gT+NE3eTk85zguwqbIOvD2Y7CYOrCAVg=";

  subPackages = [
    "cmd/golem"
    "cmd/golemd"
  ];

  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/golemd \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.tmux
          pkgs.git
          pkgs.bash
          pi-coding-agent
        ]
      }
  '';

  # Integration tests require a working tmux runtime.
  doCheck = false;

  meta = with pkgs.lib; {
    description = "Standalone delegated-agent daemon and CLI";
    homepage = "https://github.com/gisikw/golem";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
