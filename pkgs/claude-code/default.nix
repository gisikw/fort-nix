{ pkgs }:

let
  version = "2.1.258";

  sources = {
    x86_64-linux = {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-${version}.tgz";
      hash = "sha256-T4DKV3hx5ViKJeLm67/pKCpvtqCTWDVt9Cu8NtvYVfQ=";
    };
    aarch64-darwin = {
      url = "https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/-/claude-code-darwin-arm64-${version}.tgz";
      hash = "sha256-3YguckeI0tWQxcE7sviMhzho4XPifuwr2t4vpRmjeok=";
    };
  };

  src = pkgs.fetchzip {
    inherit (sources.${pkgs.stdenv.hostPlatform.system}) url hash;
  };
in

pkgs.stdenvNoCC.mkDerivation rec {
  pname = "claude-code";
  inherit version src;

  nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.makeWrapper
    pkgs.patchelf
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 claude $out/bin/claude
  '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    patchelf --set-interpreter ${pkgs.stdenv.cc.bintools.dynamicLinker} $out/bin/claude
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --unset DEV
  '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
    # Darwin binary is already self-contained; just disable auto-update
  '' + ''

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Agentic coding tool that lives in your terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = builtins.attrNames sources;
    mainProgram = "claude";
  };
}
