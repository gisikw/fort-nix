{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "opencode";
  version = "1.2.10";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${version}.tgz";
    hash = "sha256-PK8azScm/N9DWbp5rxuJ74d3VfoJKCe8FjdEZ9V8+WI=";
  };

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode $out/bin/opencode
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Open source AI coding agent for your terminal";
    homepage = "https://opencode.ai";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "opencode";
  };
}
