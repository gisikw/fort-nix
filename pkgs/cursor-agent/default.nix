{ pkgs }:

let
  version = "2026.02.13-41ac335";
in
pkgs.stdenv.mkDerivation {
  pname = "cursor-agent";
  inherit version;

  src = pkgs.fetchzip {
    url = "https://downloads.cursor.com/lab/${version}/linux/x64/agent-cli-package.tar.gz";
    hash = "sha256-0cUwXwZPxZctFiwR0/ULBy2igpyg6lF4UTqInuV5fvk=";
  };

  nativeBuildInputs = with pkgs; [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = with pkgs; [
    stdenv.cc.cc.lib  # libstdc++
  ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/cursor-agent $out/bin
    cp -r . $out/lib/cursor-agent/
    chmod +x $out/lib/cursor-agent/cursor-agent $out/lib/cursor-agent/cursor-askpass

    # Wrapper that points to the installed location
    makeWrapper $out/lib/cursor-agent/cursor-agent $out/bin/cursor-agent
  '';

  meta = with pkgs.lib; {
    description = "Cursor AI agent CLI";
    homepage = "https://cursor.com";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cursor-agent";
  };
}
