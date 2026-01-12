{ pkgs }:

pkgs.stdenv.mkDerivation rec {
  pname = "opencode";
  version = "1.1.14";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${version}.tgz";
    hash = "sha256-hwU0UJYCoBH3NdMhRWrUbtWz6gEBXndCLIYNzZo0Hl0=";
  };

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];

  # No build needed - just install the binary
  dontBuild = true;

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
