{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "opencode";
  version = "1.2.10";

  src = pkgs.fetchzip {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
    hash = "sha256-n4u6zCN7Wrh0TAgNEBN+k/HUu+uCJHEQkvT6dAxYR/Y=";
  };

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 opencode $out/bin/opencode
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
