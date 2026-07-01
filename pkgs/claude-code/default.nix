{ pkgs }:

pkgs.stdenvNoCC.mkDerivation rec {
  pname = "claude-code";
  version = "2.1.118";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-${version}.tgz";
    hash = "sha256-kxdVAdImUstZoHQMrcFyouXNmtxQj/xOmei9wQuWqn0=";
  };

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.patchelf
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 claude $out/bin/claude
    patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} $out/bin/claude
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --unset DEV

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Agentic coding tool that lives in your terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude";
  };
}
