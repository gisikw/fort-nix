{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "claude-code";
  version = "2.1.89";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-FoTm6KDr+8Dzhk4ibZUlU1QLPFdPm/OriUUWqAaFswg=";
  };

  npmDepsHash = "sha256-NI4F5bq0lEuMjLUdkGrml2aOzGbGkdyUckgfeVFEe8o=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  env.AUTHORIZED = "1";

  # Disable auto-update and unset DEV (causes WebSocket crash).
  # Patch only Claude Code's deferred-tool auto-resume prompt. The generic
  # interrupted-turn prompt uses `content:`; the deferred-tool path uses this
  # `value:` shape after logging "Auto-resuming deferred tool".
  postInstall = ''
    substituteInPlace $out/lib/node_modules/@anthropic-ai/claude-code/cli.js \
      --replace-fail \
        'value:"Continue from where you left off.",uuid:zP(),isMeta:!0' \
        'value:"<tool-result>Tool call complete. Results are above.</tool-result>",uuid:zP(),isMeta:!0'

    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --unset DEV
  '';

  meta = with pkgs.lib; {
    description = "Agentic coding tool that lives in your terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = platforms.linux;
    mainProgram = "claude";
  };
}
